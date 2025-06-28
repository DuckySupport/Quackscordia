--[=[
@c LimitedCache x Cache
@mt mem
@d A cache with a fixed capacity that evicts the least recently used items.
]=]

local Cache = require('iterables/Cache')
local Deque = require('utils/Deque')

local LimitedCache = require('class')('LimitedCache', Cache)

function LimitedCache:__init(limit, constructor, parent)
	Cache.__init(self, {}, constructor, parent)
	self._limit = limit
	self._lru = Deque()
end

local function promote(self, k)
	local lru = self._lru
	if lru:remove(k) then
		lru:push(k)
		return true
	end
end

function LimitedCache:get(k)
	local obj = self._objects[k]
	if obj then
		promote(self, k)
	end
	return obj
end

function LimitedCache:_insert(data, parent)
	local k = assert(self._hash(data))
	local old = self._objects[k]

	if old then
		old:_load(data)
		promote(self, k)
		return old
	end

	if self._count >= self._limit then
		local lru_k = self._lru:shift()
		if lru_k then
			self:_delete(lru_k)
		end
	end

	if self._deleted[k] then
		local deleted = self._deleted[k]
		self._deleted[k] = nil
		self._objects[k] = deleted
		self._count = self._count + 1
		self._lru:push(k)
		deleted:_load(data)
		return deleted
	else
		local obj = self._constructor(data, parent or self._parent)
		self._objects[k] = obj
		self._count = self._count + 1
		self._lru:push(k)
		return obj
	end
end

function LimitedCache:_delete(k)
	local old = Cache._delete(self, k)
	if old then
		self._lru:remove(k)
	end
	return old
end

return LimitedCache
