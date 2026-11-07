local RegisterNetEvent, AddEventHandler = RegisterNetEvent, AddEventHandler
local TriggerClientEvent, TriggerLatentClientEvent = TriggerClientEvent, TriggerLatentClientEvent
local DoesPlayerExist, SetTimeout, GetGameTimer = DoesPlayerExist, SetTimeout, GetGameTimer
local type, select, pcall, tostring, error = type, select, pcall, tostring, error
local mathType, huge, floor, max, min, ceil = math.type, math.huge, math.floor, math.max, math.min, math.ceil
local pack, unpack, msgpackPack = table.pack, table.unpack, msgpack.pack

local PREFIX = GetCurrentResourceName() .. ':'
local REPLY = PREFIX .. 'rpc:reply'
local MAX_ID = 2147483647
local SAFE_INT = 9007199254740991

local config = {
    rate = { 10, 10 },
    burst = 8,
    flood = { 30, 10 },
    stringMaxLen = 1024,
    tableMaxLen = 256,
    tableMaxDepth = 6,
    tableMaxNodes = 4096,
    latentAbove = 900,
    latentBps = 16000,
    latentGap = 400,
}

local defs, tokens, stamps, drops, running, lanes, clientEvents = {}, {}, {}, {}, {}, {}, {}
local onViolation = function(src, kind, detail)
    print(('^3[rpc] %s from %s (%s): %s^7'):format(kind, src, GetPlayerName(src) or '?', detail))
end
local onError = function(name, src, err)
    print(('^1[rpc] %s failed for %s: %s^7'):format(name, src, tostring(err)))
end

Rpc = {}

function Rpc.configure(opts)
    for k, v in pairs(opts) do
        config[k] = v
    end
end

function Rpc.onViolation(fn)
    onViolation = fn
end

function Rpc.onError(fn)
    onError = fn
end

local function clientEvent(name)
    local ev = clientEvents[name]
    if not ev then
        ev = PREFIX .. 'c:' .. name
        clientEvents[name] = ev
    end
    return ev
end

local function isInteger(v)
    if mathType(v) == 'integer' then return v >= -SAFE_INT and v <= SAFE_INT end
    return type(v) == 'number' and v == floor(v) and v >= -SAFE_INT and v <= SAFE_INT
end

local function tableSize(t, limit)
    local n = 0
    for _ in next, t do
        n = n + 1
        if n > limit then return n end
    end
    return n
end

local function deepSize(t, depth, budget)
    if depth > config.tableMaxDepth then return false, budget end
    for k, v in next, t do
        budget = budget - 1
        if budget < 0 or type(k) == 'table' then return false, budget end
        if type(v) == 'table' then
            local ok
            ok, budget = deepSize(v, depth + 1, budget)
            if not ok then return false, budget end
        elseif type(v) == 'number' and (v ~= v or v == huge or v == -huge) then
            return false, budget
        end
    end
    return true, budget
end

local checks = {
    number = function(v)
        return type(v) == 'number' and v == v and v > -huge and v < huge
    end,
    integer = isInteger,
    string = function(v)
        return type(v) == 'string'
    end,
    boolean = function(v)
        return type(v) == 'boolean'
    end,
    table = function(v)
        return type(v) == 'table'
    end,
}

local function compileRule(rule)
    if type(rule) == 'string' then rule = { rule } end
    local kind = rule.type or rule[1]
    if not checks[kind] then error(('[rpc] unknown schema type: %s'):format(tostring(kind)), 3) end
    local oneOf
    if rule.oneOf then
        oneOf = {}
        for i = 1, #rule.oneOf do
            oneOf[rule.oneOf[i]] = true
        end
    end
    local maxLen = rule.maxLen
    if not maxLen and kind == 'string' then maxLen = config.stringMaxLen end
    if not maxLen and kind == 'table' then maxLen = config.tableMaxLen end
    return {
        check = checks[kind],
        kind = kind,
        min = rule.min,
        max = rule.max,
        maxLen = maxLen,
        oneOf = oneOf,
        optional = rule.optional or false,
    }
end

local function valid(rule, v)
    if v == nil then return rule.optional end
    if not rule.check(v) then return false end
    local kind = rule.kind
    if kind == 'number' or kind == 'integer' then
        if (rule.min and v < rule.min) or (rule.max and v > rule.max) then return false end
    elseif kind == 'string' then
        local len = #v
        if len > rule.maxLen or (rule.min and len < rule.min) then return false end
    elseif kind == 'table' then
        if tableSize(v, rule.maxLen) > rule.maxLen or not deepSize(v, 1, config.tableMaxNodes) then return false end
    end
    return not rule.oneOf or rule.oneOf[v] == true
end

local function validate(schema, ...)
    if select('#', ...) > #schema then return false end
    for i = 1, #schema do
        if not valid(schema[i], (select(i, ...))) then return false end
    end
    return true
end

local function allow(src, name, rate, burst)
    local bucket, stamp = tokens[src], stamps[src]
    if not bucket then
        bucket, stamp = {}, {}
        tokens[src], stamps[src] = bucket, stamp
    end
    local now = GetGameTimer()
    local left = bucket[name]
    if left then
        left = min(burst, left + (now - stamp[name]) * rate[1] / (rate[2] * 1000))
    else
        left = burst
    end
    stamp[name] = now
    if left < 1 then
        bucket[name] = left
        return false
    end
    bucket[name] = left - 1
    return true
end

local function flooding(src, name)
    local list = drops[src]
    if not list then
        list = {}
        drops[src] = list
    end
    local now = GetGameTimer()
    local entry = list[name]
    if not entry or now - entry[1] > config.flood[2] * 1000 then
        entry = { now, 0 }
        list[name] = entry
    end
    entry[2] = entry[2] + 1
    return entry[2] == config.flood[1]
end

local function refuse(src, id, limited)
    if id then TriggerClientEvent(REPLY, src, id, false, limited) end
end

function Rpc.latent(target, event, bps, ...)
    if type(target) ~= 'number' or target < 1 then return TriggerLatentClientEvent(event, target, bps, ...) end
    local lane = lanes[target]
    if not lane then
        lane = { free = 0 }
        lanes[target] = lane
    end
    local now = GetGameTimer()
    local size = #msgpackPack(pack(...))
    local start = max(now, lane.free)
    lane.free = start + ceil(size * 1000 / bps) + config.latentGap
    if start == now then return TriggerLatentClientEvent(event, target, bps, ...) end
    local args = pack(...)
    SetTimeout(start - now, function()
        if lanes[target] ~= lane or not DoesPlayerExist(target) then return end
        TriggerLatentClientEvent(event, target, bps, unpack(args, 1, args.n))
    end)
end

local function send(target, event, ...)
    local ok, packed = pcall(msgpackPack, pack(...))
    if ok and #packed > config.latentAbove then return Rpc.latent(target, event, config.latentBps, ...) end
    TriggerClientEvent(event, target, ...)
end

local function finish(src, name, id, ok, ...)
    if not ok then
        onError(name, src, (...))
        return refuse(src, id, false)
    end
    if id then send(src, REPLY, id, true, ...) end
end

local function dispatch(name, def, src, id, ...)
    if type(src) ~= 'number' or src <= 0 or not DoesPlayerExist(src) then return end
    if id ~= false and not (mathType(id) == 'integer' and id > 0 and id <= MAX_ID) then
        return onViolation(src, 'bad_id', name)
    end
    id = id or nil
    if not allow(src, name, def.rate, def.burst) then
        refuse(src, id, true)
        if flooding(src, name) then onViolation(src, 'flood', name) end
        return
    end
    if not validate(def.schema, ...) then return onViolation(src, 'schema', name) end
    if def.parallel then return finish(src, name, id, pcall(def.handler, src, ...)) end
    local busy = running[src]
    if not busy then
        busy = {}
        running[src] = busy
    end
    if busy[name] then return refuse(src, id, true) end
    busy[name] = true
    finish(src, name, id, pcall(def.handler, src, ...))
    if running[src] == busy then busy[name] = nil end
end

function Rpc.register(name, def)
    if type(name) ~= 'string' or name:find('^rpc:') or name:find('^c:') then
        error(('[rpc] invalid name: %s'):format(tostring(name)), 2)
    end
    if defs[name] then error(('[rpc] %s is already registered'):format(name), 2) end
    if type(def.handler) ~= 'function' then error(('[rpc] %s has no handler'):format(name), 2) end
    local schema = {}
    for i = 1, #(def.schema or {}) do
        schema[i] = compileRule(def.schema[i])
    end
    local rate = def.rate or config.rate
    local compiled = {
        schema = schema,
        rate = rate,
        burst = max(rate[1], config.burst),
        handler = def.handler,
        parallel = def.parallel == true,
    }
    defs[name] = compiled
    RegisterNetEvent(PREFIX .. name, function(id, ...)
        dispatch(name, compiled, source, id, ...)
    end)
end

function Rpc.emit(target, name, ...)
    send(target, clientEvent(name), ...)
end

AddEventHandler('playerDropped', function()
    local src = source
    tokens[src], stamps[src], drops[src], running[src], lanes[src] = nil, nil, nil, nil, nil
end)
