--[[ NOTE:
These standard library extensions are NOT used in Discordia. They are here as a
convenience for those who wish to use them.

There are multiple ways to implement some of these commonly used functions.
Please pay attention to the implementations used here and make sure that they
match your expectations.

You may freely add to, remove, or edit any of the code here without any effect
on the rest of the library. If you do make changes, do be careful when sharing
your expectations with other users.

You can inject these extensions into the standard Lua global tables by
calling either the main module (ex: discordia.extensions()) or each sub-module
(ex: discordia.extensions.string())
]]

local sort, concat = table.sort, table.concat
local insert, remove = table.insert, table.remove
local byte, char = string.byte, string.char
local gmatch, match = string.gmatch, string.match
local rep, find, sub = string.rep, string.find, string.sub
local min, max, random = math.min, math.max, math.random
local ceil, floor = math.ceil, math.floor

local table = {}

function table.count(tbl)
    tbl = tbl or {}
	local n = 0
	for _ in pairs(tbl) do
		n = n + 1
	end
	return n
end

function table.deepcount(tbl)
    if (not tbl) then return 0 end
	local n = 0
	for _, v in pairs(tbl) do
		n = type(v) == 'table' and n + table.deepcount(v) or n + 1
	end
	return n
end

function table.concatFn(tbl, connector, fn)
    if (not tbl) or (not connector) or (not fn) then return "" end
	local ret = ""
	local c = 0

	for i, v in pairs(tbl) do
		c = c + 1
		ret = ret .. fn(v, i) .. ((c < table.count(tbl) and connector) or "")
	end

	return ret
end

function table.copy(tbl)
    if (not tbl) then return {} end
	local ret = {}
	for k, v in pairs(tbl) do
		ret[k] = v
	end
	return ret
end

function table.deepcopy(tbl, layer)
    if (not tbl) then return {} end
	layer = layer or 1
	if layer > 25 then
		return nil
	end
	local ret = {}
	for k, v in pairs(tbl) do
		ret[k] = type(v) == 'table' and table.deepcopy(v, layer + 1) or v
	end
	return ret
end

function table.deeppairs(tbl, fn)
	if not tbl then return end

	local keys = {}
	for k in pairs(tbl) do
		keys[#keys+1] = k
	end

	for _, k in ipairs(keys) do
		local v = tbl[k]
		if type(v) == "table" then
			table.deeppairs(v, fn)
		else
			tbl[k] = fn(tbl, k, v)
		end
	end
end

function table.reverse(tbl)
    if (not tbl) then return end
	for i = 1, #tbl do
		insert(tbl, i, remove(tbl))
	end
end

function table.reversed(tbl)
    if (not tbl) then return {} end
	local ret = {}
	for i = #tbl, 1, -1 do
		insert(ret, tbl[i])
	end
	return ret
end

function table.keys(tbl)
    if (not tbl) then return {} end
	local ret = {}
	for k in pairs(tbl) do
		insert(ret, k)
	end
	return ret
end

function table.values(tbl)
    if (not tbl) then return {} end
	local ret = {}
	for _, v in pairs(tbl) do
		insert(ret, v)
	end
	return ret
end

function table.randomipair(tbl)
    if (not tbl) then return end
	local i = random(#tbl)
	return i, tbl[i]
end

function table.randompair(tbl)
    if (not tbl) then return end
	local rand = random(table.count(tbl))
	local n = 0
	for k, v in pairs(tbl) do
		n = n + 1
		if n == rand then
			return k, v
		end
	end
end

function table.sorted(tbl, fn)
    if (not tbl) then return {} end
	local ret = {}
	for i, v in ipairs(tbl) do
		ret[i] = v
	end
	sort(ret, fn)
	return ret
end

function table.search(tbl, value)
    if (not tbl) or (not value) then return end
	for k, v in pairs(tbl) do
		if v == value then
			return k
		end
	end
	return nil
end

function table.slice(tbl, start, stop, step)
    if (not tbl) then return {} end
	local ret = {}
	for i = start or 1, stop or #tbl, step or 1 do
		insert(ret, tbl[i])
	end
	return ret
end

function table.find(tbl, val)
    if (not tbl) or (not val) then return end
	for i, v in pairs(tbl) do
		if type(val) == "function" then
			if val(v, i) then
				return v, i
			end
		elseif v == val then
			return v, i
		end
	end
end

--[[
If the query (~= table) is found in a table, it returns the current table it found it in

local tbl = {
	{
		item = "gold"
	},
	{
		item = "trash"
	}
}

table.findtable(tbl, "gold") returns:
	{
		item = "gold"
	}
]]--

---@param tbl table The table to search in
---@param query number|string|boolean What to search for
---@return table|nil The table it found it in
function table.findtable(input, query)
	local tbl = table.deepcopy(input)
	local ret

	table.deeppairs(tbl, function(t, i, v)
		if v == query then
			ret = t
		end
	end)

	return ret
end

function table.delete(tbl, val)
    tbl = tbl or {}
    if not val then return false end
	for i, v in pairs(tbl) do
		if (type(val) == "function" and val(v)) or (type(val) ~= "function" and (i == val or v == val)) then
			remove(tbl, i)
			return true
		end
	end

	return false
end

function table.shuffle(tbl)
    tbl = tbl or {}
	for i = #tbl, 2, -1 do
		local j = random(i)
		tbl[i], tbl[j] = tbl[j], tbl[i]
	end
	return tbl
end

function table.chop(tbl, chop)
    tbl = tbl or {}
    local new = {}

    for i, v in pairs(tbl) do
        insert(new, v)
        if i == chop then
            break
        end
    end

    return new
end

local string = {}

function string.split(str, delim)
	local ret = {}
	if not str then
		return ret
	end
	if not delim or delim == '' then
		for c in gmatch(str, '.') do
			insert(ret, c)
		end
		return ret
	end
	local n = 1
	while true do
		local i, j = find(str, delim, n)
		if not i then break end
		insert(ret, sub(str, n, i - 1))
		n = j + 1
	end
	insert(ret, sub(str, n))
	return ret
end

function string.split(str, delim)
	local ret = {}
	if not str then
		return ret
	end
	if not delim or delim == '' then
		for c in gmatch(str, '.') do
			insert(ret, c)
		end
		return ret
	end
	local n = 1
	while true do
		local i, j = find(str, delim, n);
		if not i then break end;
		insert(ret, sub(str, n, i - 1));
		n = j + 1;
	end;
	insert(ret, sub(str, n));
	return ret;
end

function string.trim(str)
	return match(str, '^%s*(.-)%s*$')
end

function string.pad(str, len, align, pattern)
	pattern = pattern or ' '
	if align == 'right' then
		return rep(pattern, (len - #str) / #pattern) .. str
	elseif align == 'center' then
		local pad = 0.5 * (len - #str) / #pattern
		return rep(pattern, floor(pad)) .. str .. rep(pattern, ceil(pad))
	else -- left
		return str .. rep(pattern, (len - #str) / #pattern)
	end
end

function string.startswith(str, pattern, plain)
	local start = 1
	return find(str, pattern, start, plain) == start
end

function string.endswith(str, pattern, plain)
	local start = #str - #pattern + 1
	return find(str, pattern, start, plain) == start
end

function string.levenshtein(str1, str2)

	if str1 == str2 then return 0 end

	local len1 = #str1
	local len2 = #str2

	if len1 == 0 then
		return len2
	elseif len2 == 0 then
		return len1
	end

	local matrix = {}
	for i = 0, len1 do
		matrix[i] = {[0] = i}
	end
	for j = 0, len2 do
		matrix[0][j] = j
	end

	for i = 1, len1 do
		for j = 1, len2 do
			local cost = byte(str1, i) == byte(str2, j) and 0 or 1
			matrix[i][j] = min(matrix[i-1][j] + 1, matrix[i][j-1] + 1, matrix[i-1][j-1] + cost)
		end
	end

	return matrix[len1][len2]

end

function string.random(len, mn, mx)
	local ret = {}
	mn = mn or 0
	mx = mx or 255
	for _ = 1, len do
		insert(ret, char(random(mn, mx)))
	end
	return concat(ret)
end

function string.capitalize(str)
	return str:sub(1,1):upper() .. str:sub(2):lower()
end

function string.removeWhitespace(str)
	local ret = "" .. str
	repeat
		ret = ret:gsub("  ", " ")
	until not string.find(ret, "  ")
	return ret
end

function string.truncate(str, len)
    if str:len() >= len then
        return str:sub(1,len - 3) .. "..."
    else
        return str
    end
end

local math = {}

function math.clamp(n, minValue, maxValue)
	return min(max(n, minValue), maxValue)
end

function math.round(n, i)
	local m = 10 ^ (i or 0)
	return floor(n * m + 0.5) / m
end

local ext = setmetatable({
	table = table,
	string = string,
	math = math,
}, {__call = function(self)
	for _, v in pairs(self) do
		v()
	end
end})

for n, m in pairs(ext) do
	setmetatable(m, {__call = function(self)
		for k, v in pairs(self) do
			_G[n][k] = v
		end
	end})
end

return ext
