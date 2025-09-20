-- This module provides utilities for asynchronous processing of Discord gateway events.
-- It includes an asynchronous JSON decoder and a batch processor for creating Discordia objects.

local lunajson = require('lunajson')
local uv = require('uv')

local AsyncProcessor = {}

-- Asynchronously decodes a JSON payload using a SAX-based parser.
-- This function is designed to be called within a coroutine.
function AsyncProcessor.decode(payload)
    local result
    local stack = {}
    local current_key

    local handler = {
        startobject = function()
            local new_obj = {}
            if #stack > 0 then
                local parent = stack[#stack]
                if type(parent) == 'table' then
                    if current_key then
                        parent[current_key] = new_obj
                    else
                        table.insert(parent, new_obj)
                    end
                end
            end
            table.insert(stack, new_obj)
        end,
        endobject = function()
            result = table.remove(stack)
        end,
        startarray = function()
            local new_arr = {}
            if #stack > 0 then
                local parent = stack[#stack]
                if type(parent) == 'table' then
                    if current_key then
                        parent[current_key] = new_arr
                    else
                        table.insert(parent, new_arr)
                    end
                end
            end
            table.insert(stack, new_arr)
        end,
        endarray = function()
            result = table.remove(stack)
        end,
        key = function(k)
            current_key = k
        end,
        string = function(v)
            local parent = stack[#stack]
            if type(parent) == 'table' then
                if current_key then
                    parent[current_key] = v
                    current_key = nil
                else
                    table.insert(parent, v)
                end
            end
        end,
        number = function(v)
            local parent = stack[#stack]
            if type(parent) == 'table' then
                if current_key then
                    parent[current_key] = v
                    current_key = nil
                else
                    table.insert(parent, v)
                end
            end
        end,
        boolean = function(v)
            local parent = stack[#stack]
            if type(parent) == 'table' then
                if current_key then
                    parent[current_key] = v
                    current_key = nil
                else
                    table.insert(parent, v)
                end
            end
        end,
        null = function()
            local parent = stack[#stack]
            if type(parent) == 'table' then
                if current_key then
                    parent[current_key] = json.null
                    current_key = nil
                else
                    table.insert(parent, json.null)
                end
            end
        end,
    }

    local parser = lunajson.newparser(payload, handler)

    -- Process the payload in chunks to allow for yielding.
    while parser:run() do
        coroutine.yield()
    end

    return result
end

-- Processes data in batches, yielding between each batch.
-- This is used to create Discordia objects without blocking the main thread.
function AsyncProcessor.process(data, handler, client, shard)
    local items = type(data) == 'table' and not data.op and not data.t and not data.s and not data.d and data or {data}
    local i = 1
    local batch_size = 10

    local function process_batch()
        for j = i, math.min(i + batch_size - 1, #items) do
            pcall(handler, items[j], client, shard)
        end
        i = i + batch_size
        if i <= #items then
            local timer = uv.new_timer()
            timer:start(0, 0, process_batch)
        end
    end

    process_batch()
end

return AsyncProcessor
