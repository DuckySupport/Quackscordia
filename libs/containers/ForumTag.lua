--[=[
@c ForumTag x Snowflake
@d Represents an forum thread tag.
]=]

local json = require('json')
local Snowflake = require('containers/abstract/Snowflake')
local Emoji = require('containers/Emoji')

local enums = require('enums')
local actionType = assert(enums.actionType)

local ForumTag, get = require('class')('ForumTag', Snowflake)

function ForumTag:__init(data, parent)
	Snowflake.__init(self, data, parent)
end

function ForumTag:_load(data)
    Snowflake._load(self, data)
    self._name = data.name
    self._moderated = data.moderated
	self._emoji_name = data.emoji_name
	self._emoji_id = type(data.emoji_id) == "string" and data.emoji_id
end

function ForumTag:_modify(payload)
	local data, err = self.client._api:modifyForumTag(self._parent.id, self._id, payload)
	if data then
		self:_load(data)
		return true
	else
		return false, err
	end
end

--[=[
@m setName
@t http
@p name string
@r boolean
@d Sets the forum tag's name.
]=]
function ForumTag:setName(name)
	return self:_modify({name = name or json.null})
end

--[=[
@m setEmoji
@t http
@p emoji table
@r boolean
@d Sets this forum tag's emoji. This must be either a string representing a unicode emoji or a table with fields `name` and `id` for custom emojis.
]=]
function ForumTag:setEmoji(emoji)
	emoji = type(emoji) == "string" and {name = emoji} or emoji
	return self:_modify({emoji_name = emoji.name or json.null, emoji_id = emoji.id or json.null})
end

--[=[
@m enableModerated
@t http
@r boolean
@d Enables the moderated feature of this forum tag. Only server moderators will be able to apply this tag.
]=]
function ForumTag:enableModerated()
	return self:_modify({moderated = true})
end

--[=[
@m disableModerated
@t http
@r boolean
@d Disabled the moderated feature of this forum tag. Anyone will be able to apply this tag.
]=]
function ForumTag:disableModerated()
	return self:_modify({moderated = false})
end

--[=[
@m delete
@t http
@r boolean
@d Permanently deletes the forum tag. This cannot be undone!
]=]
function ForumTag:delete()
	local data, err = self.client._api:deleteForumTag(self._parent._id, self._id)
	if data then
		local cache = self._parent._available_tags
		if cache then
			cache:_delete(self._id)
		end
		return true
	else
		return false, err
	end
end


--[=[@p name string The name this forum tag.]=]
function get.name(self)
	return self._name
end

--[=[@p emojiName string The name of the emoji used in this forum tag.
This will be the raw string for a standard emoji.]=]
function get.emojiName(self)
	return self._emoji_name
end

--[=[@p emojiId string/nil The ID of the emoji used in this forum tag if it is a custom emoji.]=]
function get.emojiId(self)
	return self._emoji_id
end

--[=[@p moderated boolean Whether or not this tag is moderated. Moderated tags can only be added by server moderators.]=]
function get.moderated(self)
	return self._moderated
end

--[=[@p channel GuildForumChannel The channel in which this forum tag exists.]=]
function get.channel(self)
	return self._parent
end

return ForumTag