--[=[
@c LimitedCache x Cache
@mt mem
@d A cache with a limited size and an LRU eviction policy.
]=]

local Cache = require('iterables/Cache')
local LimitedCache = require('class')('LimitedCache', Cache)

function LimitedCache:__init(limit, constructor, parent)
	Cache.__init(self, {}, constructor, parent)
	self._limit = limit
	self._keys = {}
end

function LimitedCache:_insert(data, parent)
	local k = assert(self._hash(data))
	local old = self._objects[k]

	if old then
		old:_load(data)
		self:_makeRecent(k)
		return old
	end

	if self._count >= self._limit then
		self:_evict()
	end

	local obj = self._constructor(data, parent or self._parent)
	self._objects[k] = obj
	self._count = self._count + 1
	table.insert(self._keys, k)
	return obj
end

function LimitedCache:get(k)
	local obj = self._objects[k]
	if obj then
		self:_makeRecent(k)
	end
	return obj
end

function LimitedCache:_makeRecent(k)
	for i, key in ipairs(self._keys) do
		if key == k then
			table.remove(self._keys, i)
			table.insert(self._keys, k)
			break
		end
	end
end

function LimitedCache:_evict()
	local oldestKey = table.remove(self._keys, 1)
	if oldestKey then
		self._objects[oldestKey] = nil
		self._count = self._count - 1
	end
end

return LimitedCache
