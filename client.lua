local TriggerServerEvent, TriggerLatentServerEvent = TriggerServerEvent, TriggerLatentServerEvent
local RegisterNetEvent, SetTimeout = RegisterNetEvent, SetTimeout
local Await = Citizen.Await
local pack, unpack, type, tostring, error = table.pack, table.unpack, type, tostring, error

local PREFIX = GetCurrentResourceName() .. ':'
local MAX_ID = 2147483647

local config = { timeout = 10000, debug = false }
local pending = {}
local serverEvents = {}
local lastId = 0

Rpc = { TIMEOUT = 'timeout', LIMITED = 'limited', REFUSED = 'refused' }

function Rpc.configure(opts)
    for k, v in pairs(opts) do
        config[k] = v
    end
end

local function serverEvent(name)
    local ev = serverEvents[name]
    if not ev then
        ev = PREFIX .. name
        serverEvents[name] = ev
    end
    return ev
end

local function settle(id, value)
    local p = pending[id]
    if not p then return end
    pending[id] = nil
    p:resolve(value)
end

RegisterNetEvent(PREFIX .. 'rpc:reply', function(id, ok, ...)
    if ok then return settle(id, pack(...)) end
    settle(id, (...) and Rpc.LIMITED or Rpc.REFUSED)
end)

local function request(trigger, name, ...)
    lastId = lastId % MAX_ID + 1
    local id = lastId
    local p = promise.new()
    pending[id] = p
    trigger(serverEvent(name), id, ...)
    SetTimeout(config.timeout, function()
        settle(id, Rpc.TIMEOUT)
    end)
    local result = Await(p)
    if type(result) == 'string' then
        Rpc.status = result
        if config.debug then print(('^3[rpc] %s: %s^7'):format(name, result)) end
        return nil
    end
    Rpc.status = nil
    return unpack(result, 1, result.n)
end

function Rpc.call(name, ...)
    return request(TriggerServerEvent, name, ...)
end

function Rpc.callLatent(name, bps, ...)
    return request(function(event, ...)
        TriggerLatentServerEvent(event, bps, ...)
    end, name, ...)
end

function Rpc.send(name, ...)
    TriggerServerEvent(serverEvent(name), false, ...)
end

function Rpc.sendLatent(name, bps, ...)
    TriggerLatentServerEvent(serverEvent(name), bps, false, ...)
end

function Rpc.on(name, fn)
    if type(name) ~= 'string' then error(('[rpc] invalid name: %s'):format(tostring(name)), 2) end
    RegisterNetEvent(PREFIX .. 'c:' .. name, fn)
end
