--[=[
@c GuildForumChannel x GuildChannel
@d Represents a forum channel in a Discord guild, where guild members
can send and receive posts (threads).
]=]

local json = require('json')

local GuildChannel = require('containers/abstract/GuildChannel')
local FilteredIterable = require('iterables/FilteredIterable')
local ForumTag = require('containers/ForumTag')
local Cache = require('iterables/Cache')
local Resolver = require('client/Resolver')

local GuildForumChannel, get = require('class')('GuildForumChannel', GuildChannel)

function GuildForumChannel:__init(data, parent)
	GuildChannel.__init(self, data, parent)
	self._available_tags = Cache({}, ForumTag, self)
	return self:_loadMore(data)
end

function GuildForumChannel:_load(data)
	GuildChannel._load(self, data)
	return self:_loadMore(data)
end

function GuildForumChannel:_loadMore(data)
	return self._available_tags and data.available_tags and self._available_tags:_load(data.available_tags, true)
end

--[=[
@m getTag
@t http?
@p id Forum-Tag-ID-Resolvable
@r ForumTag
@d Gets a forum tag object by ID. If the object is already cached, then the cached
object will be returned; otherwise, an HTTP request is made.
]=]
function GuildForumChannel:getTag(id)
	id = Resolver.forumTagId(id)
	local message = self._available_tags:get(id)
	if message then
		return message
	else
		local data, err = self.client._api:getForumTag(self._id, id)
		if data then
			return self._available_tags:_insert(data)
		else
			return nil, err
		end
	end
end

--[=[
@m createTag
@t http
@p name string
@op emoji table
@op moderated boolean
@r ForumTag
@d Creates a new forum tag within this forum channel.
]=]
function GuildForumChannel:createTag(name, emoji, moderated)
	emoji = type(emoji) == "string" and {name = emoji} or emoji

	local data, err = self.client._api:createForumTag(self._id, {name = name, emoji_name = emoji and emoji.name, emoji_id = emoji and emoji.id, moderated = not not moderated})
	if data then
		return self._available_tags:_insert(data)
	else
		return nil, err
	end
end

--[=[
@m setRateLimit
@t http
@p limit number
@r boolean
@d Sets the channel's slowmode rate limit in seconds. This must be between 0 and 120.
Passing 0 or `nil` will clear the limit.
]=]
function GuildForumChannel:setRateLimit(limit)
	return self:_modify({rate_limit_per_user = limit or json.null})
end

--[=[
@m enableNSFW
@t http
@r boolean
@d Enables the NSFW setting for the channel. NSFW channels are hidden from users
until the user explicitly requests to view them.
]=]
function GuildForumChannel:enableNSFW()
	return self:_modify({nsfw = true})
end

--[=[
@m disableNSFW
@t http
@r boolean
@d Disables the NSFW setting for the channel. NSFW channels are hidden from users
until the user explicitly requests to view them.
]=]
function GuildForumChannel:disableNSFW()
	return self:_modify({nsfw = false})
end

--[=[@p nsfw boolean Whether this channel is marked as NSFW (not safe for work).]=]
function get.nsfw(self)
	return self._nsfw or false
end

--[=[@p rateLimit number Slowmode rate limit per guild member.]=]
function get.rateLimit(self)
	return self._rate_limit_per_user or 0
end

--[=[@p members FilteredIterable A filtered iterable of guild members that have
permission to read this channel. If you want to check whether a specific member
has permission to read this channel, it would be better to get the member object
elsewhere and use `Member:hasPermission` rather than check whether the member
exists here.]=]
function get.members(self)
	if not self._members then
		self._members = FilteredIterable(self._parent._members, function(m)
			return m:hasPermission(self, 'readMessages')
		end)
	end
	return self._members
end

function get.availableTags(self)
	return self._available_tags
end

return GuildForumChannel