--[=[
@c Message x Snowflake
@d Represents a text message sent in a Discord text channel. Messages can contain
simple content strings, rich embeds, attachments, or reactions.
]=]

local json = require('json')
local enums = require('enums')
local constants = require('constants')
local Cache = require('iterables/Cache')
local ArrayIterable = require('iterables/ArrayIterable')
local Snowflake = require('containers/abstract/Snowflake')
local Reaction = require('containers/Reaction')
local Resolver = require('client/Resolver')

local insert = table.insert
local null = json.null
local format = string.format
local messageFlag = assert(enums.messageFlag)
local channelType = assert(enums.channelType)
local band, bor, bnot = bit.band, bit.bor, bit.bnot

local Message, get = require('class')('Message', Snowflake)

function Message:__init(data, parent)
	Snowflake.__init(self, data, parent)
	self._author = self.client._users:_insert(data.author)
	if data.member then
		data.member.user = data.author
		self._parent.guild._members:_insert(data.member)
	end
	self._timestamp = nil -- waste of space; can be calculated from Snowflake ID
	if data.reactions and #data.reactions > 0 then
		self._reactions = Cache(data.reactions, Reaction, self)
	end
	return self:_loadMore(data)
end

function Message:_load(data)
	Snowflake._load(self, data)
	return self:_loadMore(data)
end

local function parseMentions(content, pattern)
	if not content:find('%b<>') then return {} end
	local mentions, seen = {}, {}
	for id in content:gmatch(pattern) do
		if not seen[id] then
			insert(mentions, id)
			seen[id] = true
		end
	end
	return mentions
end

function Message:_loadMore(data)

	local mentions = {}
	if data.mentions then
		for _, user in ipairs(data.mentions) do
			mentions[user.id] = true
			if user.member then
				user.member.user = user
				self._parent.guild._members:_insert(user.member)
			else
				self.client._users:_insert(user)
			end
		end
	end

	if data.referenced_message and data.referenced_message ~= null then
		if mentions[data.referenced_message.author.id] then
			self._reply_target = data.referenced_message.author.id
		end
		self._referencedMessage = self._parent._messages:_insert(data.referenced_message)
	elseif data.message_reference and data.message_reference ~= null then
		local guild = self.client:getGuild(data.message_reference.guild_id)
		local channel = guild and guild:getChannel(data.message_reference.channel_id)
		local message = channel and channel:getMessage(data.message_reference.message_id)
		self._forwardedMessage = message or nil
	end

	local content = data.content
	if content then
		if self._mentioned_users then
			self._mentioned_users._array = parseMentions(content, '<@!?(%d+)>')
			if self._reply_target then
				insert(self._mentioned_users._array, 1, self._reply_target)
			end
		end
		if self._mentioned_roles then
			self._mentioned_roles._array = parseMentions(content, '<@&(%d+)>')
		end
		if self._mentioned_channels then
			self._mentioned_channels._array = parseMentions(content, '<#(%d+)>')
		end
		self._clean_content = nil
	end

	if data.embeds then
		self._embeds = #data.embeds > 0 and data.embeds or nil
	end

	if data.attachments then
		self._attachments = #data.attachments > 0 and data.attachments or nil
	end

	if data.sticker_items then
		self._sticker_items = #data.sticker_items > 0 and data.sticker_items or nil
	end
	if data.sticker_items then
		self._sticker_items = #data.sticker_items > 0 and data.sticker_items or nil
	end

end

function Message:_addReaction(d)

	local reactions = self._reactions

	if not reactions then
		reactions = Cache({}, Reaction, self)
		self._reactions = reactions
	end

	local emoji = d.emoji
	local k = emoji.id ~= null and emoji.id or emoji.name
	local reaction = reactions:get(k)

	if reaction then
		reaction._count = reaction._count + 1
		if d.user_id == self.client._user._id then
			reaction._me = true
		end
	else
		d.me = d.user_id == self.client._user._id
		d.count = 1
		reaction = reactions:_insert(d)
	end
	return reaction

end

function Message:_removeReaction(d)

	local reactions = self._reactions
	if not reactions then return nil end

	local emoji = d.emoji
	local k = emoji.id ~= null and emoji.id or emoji.name
	local reaction = reactions:get(k) or nil

	if not reaction then return nil end -- uncached reaction?

	reaction._count = reaction._count - 1
	if d.user_id == self.client._user._id then
		reaction._me = false
	end

	if reaction._count == 0 then
		reactions:_delete(k)
	end

	return reaction

end

function Message:_setOldContent(d)
	local ts = d.edited_timestamp
	if not ts then return end
	local old = self._old
	if old then
		old[ts] = old[ts] or self._content
	else
		self._old = {[ts] = self._content}
	end
end

function Message:_modify(payload, files)
	local data, err = self.client._api:editMessage(self._parent._id, self._id, payload, files)
	if data then
		self:_setOldContent(data)
		self:_load(data)
		return true
	else
		return false, err
	end
end

--[=[
@m setContent
@t http
@p content string
@r boolean
@d Sets the message's content. The message must be authored by the current user
(ie: you cannot change the content of messages sent by other users). The content
must be from 1 to 2000 characters in length.
]=]
function Message:setContent(content)
	return self:_modify({
		content = content or null,
		allowed_mentions = {
			parse = {'users', 'roles', 'everyone'},
			replied_user = not not self._reply_target,
		},
	})
end

--[=[
@m setEmbed
@t http
@p embed table
@r boolean
@d Sets the message's embed. The message must be authored by the current user.
(ie: you cannot change the embed of messages sent by other users).
]=]
function Message:setEmbed(embed)
	return self:_modify({embed = embed or null})
end

--[=[
@m hideEmbeds
@t http
@r boolean
@d Hides all embeds for this message.
]=]
function Message:hideEmbeds()
	local flags = bor(self._flags or 0, messageFlag.suppressEmbeds)
	return self:_modify({flags = flags})
end

--[=[
@m showEmbeds
@t http
@r boolean
@d Shows all embeds for this message.
]=]
function Message:showEmbeds()
	local flags = band(self._flags or 0, bnot(messageFlag.suppressEmbeds))
	return self:_modify({flags = flags})
end

--[=[
@m hasFlag
@t mem
@p flag Message-Flag-Resolvable
@r boolean
@d Indicates whether the message has a particular flag set.
]=]
function Message:hasFlag(flag)
	flag = Resolver.messageFlag(flag)
	return band(self._flags or 0, flag) > 0
end

--[=[
@m update
@t http
@p data table
@r boolean
@d Sets multiple properties of the message at the same time using a table similar
to the one supported by `TextChannel.send`, except only `content` and `embed(s)`
are valid fields; `mention(s)`, `file(s)`, etc are not supported. The message
must be authored by the current user. (ie: you cannot change the embed of messages
sent by other users).
]=]

local function parseFile(obj, files)
	if type(obj) == 'string' then
		local data, err = readFileSync(obj)
		if not data then
			return nil, err
		end
		files = files or {}
		insert(files, {remove(splitPath(obj)), data})
	elseif type(obj) == 'table' and type(obj[1]) == 'string' and type(obj[2]) == 'string' then
		files = files or {}
		insert(files, obj)
	else
		return nil, 'Invalid file object: ' .. tostring(obj)
	end
	return files
end

function Message:update(data)
	local files
	if data.file then
		files, err = parseFile(data.file)
		if err then
			return nil, err
		end
	end
	if type(data.files) == 'table' then
		for _, file in ipairs(data.files) do
			files, err = parseFile(file, files)
			if err then
				return nil, err
			end
		end
	end

	return self:_modify({
		content = data.content or null,
		embed = data.embed or null,
		embeds = data.embeds or null,
		components = data.components or null,
		allowed_mentions = {
			parse = {'users', 'roles', 'everyone'},
			replied_user = not not self._reply_target,
		}
	}, files)
end

--[=[
@m pin
@t http
@r boolean
@d Pins the message in the channel.
]=]
function Message:pin()
	local data, err = self.client._api:addPinnedChannelMessage(self._parent._id, self._id)
	if data then
		self._pinned = true
		return true
	else
		return false, err
	end
end

--[=[
@m unpin
@t http
@r boolean
@d Unpins the message in the channel.
]=]
function Message:unpin()
	local data, err = self.client._api:deletePinnedChannelMessage(self._parent._id, self._id)
	if data then
		self._pinned = false
		return true
	else
		return false, err
	end
end

--[=[
@m addReaction
@t http
@p emoji Emoji-Resolvable
@r boolean
@d Adds a reaction to the message. Note that this does not return the new reaction
object; wait for the `reactionAdd` event instead.
]=]
function Message:addReaction(emoji)
	emoji = Resolver.emoji(emoji)
	local data, err = self.client._api:createReaction(self._parent._id, self._id, emoji)
	if data then
		return true
	else
		return false, err
	end
end

--[=[
@m removeReaction
@t http
@p emoji Emoji-Resolvable
@op id User-ID-Resolvable
@r boolean
@d Removes a reaction from the message. Note that this does not return the old
reaction object; wait for the `reactionRemove` event instead. If no user is
indicated, then this will remove the current user's reaction.
]=]
function Message:removeReaction(emoji, id)
	emoji = Resolver.emoji(emoji)
	local data, err
	if id then
		id = Resolver.userId(id)
		data, err = self.client._api:deleteUserReaction(self._parent._id, self._id, emoji, id)
	else
		data, err = self.client._api:deleteOwnReaction(self._parent._id, self._id, emoji)
	end
	if data then
		return true
	else
		return false, err
	end
end

--[=[
@m clearReactions
@t http
@r boolean
@d Removes all reactions from the message.
]=]
function Message:clearReactions()
	local data, err = self.client._api:deleteAllReactions(self._parent._id, self._id)
	if data then
		return true
	else
		return false, err
	end
end

--[=[
@m delete
@t http
@r boolean
@d Permanently deletes the message. This cannot be undone!
]=]
function Message:delete()
	local data, err = self.client._api:deleteMessage(self._parent._id, self._id)
	if data then
		local cache = self._parent._messages
		if cache then
			cache:_delete(self._id)
		end
		return true
	else
		return false, err
	end
end

--[=[
@m reply
@t http
@p content string/table
@r Message
@d Equivalent to `Message.channel:send(content)`.
]=]
function Message:reply(content, silent, reference, mention)
	reference = ((reference == nil) and true) or false
	mention = not not mention
        
   	if type(content) == "table" and reference then
        content.reference = {message = self.id, mention = mention}
    elseif type(content) == "string" and reference then
        content = {content = content, reference = {message = self.id, mention = mention}}
    end
	return self._parent:send(content, silent)
end

function Message:success(content, silent, emoji)
	emoji = (emoji and type(emoji) == "string") or _G.emojis.success
	return self:reply({embed = {description = emoji .. " " .. content, color = _G.colors.success}}, silent)
end

function Message:warning(content, silent, emoji)
	emoji = (emoji and type(emoji) == "string") or _G.emojis.warning
	return self:reply({embed = {description = emoji .. " " .. content, color = _G.colors.warning}}, silent)
end

function Message:fail(content, silent, emoji)
	emoji = (emoji and type(emoji) == "string") or _G.emojis.fail
	return self:reply({embed = {description = emoji .. " " .. content, color = _G.colors.fail}}, silent)
end

function Message:heavyred(content, silent, emoji)
	emoji = (emoji and type(emoji) == "string") or _G.emojis.error
	return self:reply({embed = {description = emoji .. " " .. content, color = _G.colors.heavyred}}, silent)
end
    
function Message:loading(content, silent)
    content = (content and (" " .. content)) or ""
    return self:reply({embed = {description = _G.emojis.loading .. content, color = _G.colors.blank}}, silent)
end

--[=[
@m crosspost
@t http
@r Message
@d Publish this announcement message to all following channels.
Returns the current Message object, for compatibility reasons.
]=]
function Message:crosspost()
	local data, err = self.client._api:crosspostMessage(self._parent._id, self._id)
	if data then
		return self._parent._messages:_insert(data)
	else
		return nil, err
	end
end

--[=[
@m startThread
@t http
@p channelData string/table
@r boolean
@d Creates a new thread channel with this message as the starter message.
There can only exist one thread per one message.
Threads started from a message are always public.

Equivalent to `Message.channel:startThread(channelData, self)`.
]=]
function Message:startThread(channelData)
	return self._channel:startThread(channelData, self)
end

--[=[@p reactions Cache An iterable cache of all reactions that exist for this message.]=]
function get.reactions(self)
	if not self._reactions then
		self._reactions = Cache({}, Reaction, self)
	end
	return self._reactions
end

--[=[@p mentionedUsers ArrayIterable An iterable array of all users that are mentioned in this message.]=]
function get.mentionedUsers(self)
	if not self._mentioned_users then
		local users = self.client._users
		local mentions = parseMentions(self._content, '<@!?(%d+)>')
		self._mentioned_users = ArrayIterable(mentions, function(id)
			return users:get(id)
		end)
	end
	return self._mentioned_users
end

function get.mentionedUsersIncludingReplies(self)
	if not self._mentioned_users then
		local users = self.client._users
		local mentions = parseMentions(self._content, '<@!?(%d+)>')
		if self._reply_target then
			insert(mentions, 1, self._reply_target)
		end
		self._mentioned_users = ArrayIterable(mentions, function(id)
			return users:get(id)
		end)
	end
	return self._mentioned_users
end


--[=[@p mentionedRoles ArrayIterable An iterable array of known roles that are mentioned in this message, excluding
the default everyone role. The message must be in a guild text channel and the
roles must be cached in that channel's guild for them to appear here.]=]
function get.mentionedRoles(self)
	if not self._mentioned_roles then
		local client = self.client
		local mentions = parseMentions(self._content, '<@&(%d+)>')
		self._mentioned_roles = ArrayIterable(mentions, function(id)
			local guild = client._role_map[id]
			return guild and guild._roles:get(id) or nil
		end)
	end
	return self._mentioned_roles
end

--[=[@p mentionedChannels ArrayIterable An iterable array of all known channels that are mentioned in this message. If
the client does not have the channel cached, then it will not appear here.]=]
function get.mentionedChannels(self)
	if not self._mentioned_channels then
		local client = self.client
		local mentions = parseMentions(self._content, '<#(%d+)>')
		self._mentioned_channels = ArrayIterable(mentions, function(id)
			local guild = client._channel_map[id]
			if guild then
				return guild._text_channels:get(id) or guild._forum_channels:get(id) or guild._thread_channels:get(id) or guild._voice_channels:get(id) or guild._categories:get(id)
			else
				return client._private_channels:get(id) or client._group_channels:get(id)
			end
		end)
	end
	return self._mentioned_channels
end

--[=[@p sticker Sticker The first sticker that is sent in this message.]=]
function get.sticker(self)
	return self.stickers and self.stickers.first or nil
end

local usersMeta = {__index = function(_, k) return '@' .. k end}
local rolesMeta = {__index = function(_, k) return '@' .. k end}
local channelsMeta = {__index = function(_, k) return '#' .. k end}
local everyone = '@' .. constants.ZWSP .. 'everyone'
local here = '@' .. constants.ZWSP .. 'here'

--[=[@p cleanContent string The message content with all recognized mentions replaced by names and with
@everyone and @here mentions escaped by a zero-width space (ZWSP).]=]
function get.cleanContent(self)

	if not self._clean_content then

		local content = self._content
		local guild = self.guild

		local users = setmetatable({}, usersMeta)
		for user in self.mentionedUsers:iter() do
			local member = guild and guild._members:get(user._id)
			users[user._id] = '@' .. (member and member._nick or user._username)
		end

		local roles = setmetatable({}, rolesMeta)
		for role in self.mentionedRoles:iter() do
			roles[role._id] = '@' .. role._name
		end

		local channels = setmetatable({}, channelsMeta)
		for channel in self.mentionedChannels:iter() do
			channels[channel._id] = '#' .. channel._name
		end

		self._clean_content = content
			:gsub('<@!?(%d+)>', users)
			:gsub('<@&(%d+)>', roles)
			:gsub('<#(%d+)>', channels)
			:gsub('<a?(:[%w_]+:)%d+>', '%1')
			:gsub('@everyone', everyone)
			:gsub('@here', here)

	end

	return self._clean_content

end

--[=[@p mentionsEveryone boolean Whether this message mentions @everyone or @here.]=]
function get.mentionsEveryone(self)
	return self._mention_everyone
end

--[=[@p pinned boolean Whether this message belongs to its channel's pinned messages.]=]
function get.pinned(self)
	return self._pinned
end

--[=[@p tts boolean Whether this message is a text-to-speech message.]=]
function get.tts(self)
	return self._tts
end

--[=[@p nonce string/number/boolean/nil Used by the official Discord client to detect the success of a sent message.]=]
function get.nonce(self)
	return self._nonce
end

--[=[@p editedTimestamp string/nil The date and time at which the message was most recently edited, represented as
an ISO 8601 string plus microseconds when available.]=]
function get.editedTimestamp(self)
	return self._edited_timestamp
end

--[=[@p oldContent table/nil Yields a table containing keys as timestamps and
value as content of the message at that time.]=]
function get.oldContent(self)
	return self._old
end

--[=[@p content string The raw message content. This should be between 0 and 2000 characters in length.]=]
function get.content(self)
	return self._content
end

--[=[@p author User The object of the user that created the message.]=]
function get.author(self)
	return self._author
end

--[=[@p user User The object of the user that created the message. Equivalent to `Message.author`.]=]
function get.user(self)
	return self._author
end

--[=[@p channel TextChannel The channel in which this message was sent.]=]
function get.channel(self)
	return self._parent
end

--[=[@p type number The message type. Use the `messageType` enumeration for a human-readable
representation.]=]
function get.type(self)
	return self._type
end

--[=[@p embed table/nil A raw data table that represents the first rich embed that exists in this
message. See the Discord documentation for more information.]=]
function get.embed(self)
	return self._embeds and self._embeds[1]
end

--[=[@p attachment table/nil A raw data table that represents the first file attachment that exists in this
message. See the Discord documentation for more information.]=]
function get.attachment(self)
	return self._attachments and self._attachments[1]
end

--[=[@p embeds table A raw data table that contains all embeds that exist for this message. If
there are none, this table will not be present.]=]
function get.embeds(self)
	return self._embeds
end

--[=[@p attachments table A raw data table that contains all attachments that exist for this message. If
there are none, this table will not be present.]=]
function get.attachments(self)
	return self._attachments
end

--[=[@p guild Guild/nil The guild in which this message was sent. This will not exist if the message
was not sent in a guild text channel. Equivalent to `Message.channel.guild`.]=]
function get.guild(self)
	return self._parent.guild
end

--[=[@p member Member/nil The member object of the message's author. This will not exist if the message
is not sent in a guild text channel or if the member object is not cached.
Equivalent to `Message.guild.members:get(Message.author.id)`.]=]
function get.member(self)
	local guild = self.guild
	return guild and guild._members:get(self._author._id)
end

--[=[@p referencedMessage Message/nil If available, the previous message that
this current message references as seen in replies.]=]
function get.referencedMessage(self)
	return self._referencedMessage
end

--[=[@p forwardedMessage Message/nil If available, the forwarded message that
this current message references.]=]
function get.forwardedMessage(self)
	return self._forwardedMessage
end

--[=[@p link string URL that can be used to jump-to the message in the Discord client.]=]
function get.link(self)
	local guild = self.guild
	return format('https://discord.com/channels/%s/%s/%s', guild and guild._id or '@me', self._parent._id, self._id)
end

--[=[@p webhookId string/nil The ID of the webhook that generated this message, if applicable.]=]
function get.webhookId(self)
	return self._webhook_id
end

return Message
