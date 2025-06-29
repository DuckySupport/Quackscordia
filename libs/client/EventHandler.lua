local enums = require('enums')
local json = require('json')

local channelType = assert(enums.channelType)
local insert = table.insert
local Resolver = require('client/Resolver')
local null = json.null

local THREAD_TYPES = require('constants').THREAD_TYPES

local function warning(client, object, id, event)
	if client._options.suppressUncachedWarning then return end
	return client:warning('Uncached %s (%s) on %s', object, id, event)
end

local function checkReady(shard)
	for _, v in pairs(shard._loading) do
		if next(v) then return end
	end
	shard._ready = true
	shard._loading = nil
	collectgarbage()
	local client = shard._client
	client:emit('shardReady', shard._id)
	for _, other in pairs(client._shards) do
		if not other._ready then return end
	end
	return client:emit('ready')
end

local function getChannel(client, d)
	local channel = client:getChannel(d.channel_id)
	if not channel then
		local fetchedChannel, err = client._api:getChannel(d.channel_id)
		if fetchedChannel then
			local t = fetchedChannel.type
			if t == channelType.private then
				channel = client._private_channels:_insert(fetchedChannel)
			elseif t == channelType.group then
				channel = client._group_channels:_insert(fetchedChannel)
			elseif THREAD_TYPES[fetchedChannel.type] then
				local parent_channel = getChannel(client, {channel_id = fetchedChannel.parent_id})
				if parent_channel then
					channel = parent_channel._thread_channels:_insert(fetchedChannel, parent_channel)
				end
			elseif fetchedChannel.guild_id then -- It's a guild channel
				local guild = client._guilds:get(fetchedChannel.guild_id)
				if not guild then
					-- Guild not cached, fetch it
					local fetchedGuild, guildErr = client._api:getGuild(fetchedChannel.guild_id)
					if fetchedGuild then
						guild = client._guilds:_insert(fetchedGuild)
					else
						if not client._options.suppressUncachedWarning then
				client:warning("Failed to fetch guild %s for channel %s: %s", fetchedChannel.guild_id, d.channel_id, guildErr)
			end
			return nil -- Cannot proceed without guild
					end
				end
				-- Now that we have a guild (cached or newly fetched), insert the channel
				if guild then -- Double check guild is not nil
					if t == channelType.text or t == channelType.news then
						channel = guild._text_channels:_insert(fetchedChannel)
					elseif t == channelType.voice then
						channel = guild._voice_channels:_insert(fetchedChannel)
					elseif t == channelType.category then
						channel = guild._categories:_insert(fetchedChannel)
					elseif t == channelType.forum then
						channel = guild._forum_channels:_insert(fetchedChannel)
					end
				end
			end
		else
			if not client._options.suppressUncachedWarning then
				client:warning("Failed to fetch channel %s: %s", d.channel_id, err)
			end
		end
	end
	return channel
end

local EventHandler = setmetatable({}, {__index = function(self, k)
	self[k] = function(_, _, shard)
		return shard:warning('Unhandled gateway event: %s', k)
	end
	return self[k]
end})

function EventHandler.READY(d, client, shard)

	shard:info('Received READY')
	shard:emit('READY')

	shard._session_id = d.session_id
	client._user = client._users:_insert(d.user)

	local guilds = client._guilds
	local group_channels = client._group_channels
	local private_channels = client._private_channels
	local relationships = client._relationships

	for _, channel in ipairs(d.private_channels) do
		if channel.type == channelType.private then
			private_channels:_insert(channel)
		elseif channel.type == channelType.group then
			group_channels:_insert(channel)
		end
	end

	local loading = shard._loading

	if d.user.bot then
		for _, guild in ipairs(d.guilds) do
			guilds:_insert(guild)
			loading.guilds[guild.id] = true
		end
	else
		if client._options.syncGuilds then
			local ids = {}
			for _, guild in ipairs(d.guilds) do
				guilds:_insert(guild)
				if not guild.unavailable then
					loading.syncs[guild.id] = true
					insert(ids, guild.id)
				end
			end
			shard:syncGuilds(ids)
		else
			guilds:_load(d.guilds)
		end
	end

	relationships:_load(d.relationships)

	for _, presence in ipairs(d.presences) do
		local relationship = relationships:get(presence.user.id)
		if relationship then
			relationship:_loadPresence(presence)
		end
	end

	return checkReady(shard)

end

function EventHandler.RESUMED(_, client, shard)
	shard:info('Received RESUMED')
	return client:emit('shardResumed', shard._id)
end

function EventHandler.GUILD_MEMBERS_CHUNK(d, client, shard)
	local guild = client._guilds:get(d.guild_id)
	if not guild then
		local fetchedGuild, err = client._api:getGuild(d.guild_id)
		if fetchedGuild then
			guild = client._guilds:_insert(fetchedGuild)
		else
			if not client._options.suppressUncachedWarning then
				return client:warning("Failed to fetch guild %s for GUILD_MEMBERS_CHUNK: %s", d.guild_id, err)
			end
			return
		end
	end
	if guild then -- Ensure guild is not nil after potential fetch attempt
		guild._members:_load(d.members)
		if shard._loading and guild._member_count == #guild._members then
			shard._loading.chunks[d.guild_id] = nil
			return checkReady(shard)
		end
	end
end

function EventHandler.GUILD_SYNC(d, client, shard)
	local guild = client._guilds:get(d.id)
	if not guild then
		local fetchedGuild, err = client._api:getGuild(d.id)
		if fetchedGuild then
			guild = client._guilds:_insert(fetchedGuild)
		else
			if not client._options.suppressUncachedWarning then
				return client:warning("Failed to fetch guild %s for GUILD_SYNC: %s", d.id, err)
			end
			return
		end
	end
	if guild then -- Ensure guild is not nil after potential fetch attempt
		guild._large = d.large
		guild:_loadMembers(d, shard)
		if shard._loading then
			shard._loading.syncs[d.id] = nil
			return checkReady(shard)
		end
	end
end

function EventHandler.CHANNEL_CREATE(d, client)
	local channel
	local t = d.type
	if t == channelType.text or t == channelType.news or t == channelType.voice or t == channelType.category or t == channelType.forum then
		local guild = client._guilds:get(d.guild_id)
		if not guild then
			local fetchedGuild, err = client._api:getGuild(d.guild_id)
			if fetchedGuild then
				guild = client._guilds:_insert(fetchedGuild)
			else
				if not client._options.suppressUncachedWarning then
					return client:warning("Failed to fetch guild %s for CHANNEL_CREATE: %s", d.guild_id, err)
				end
				return
			end
		end
		if guild then
			if t == channelType.text or t == channelType.news then
				channel = guild._text_channels:_insert(d)
			elseif t == channelType.voice then
				channel = guild._voice_channels:_insert(d)
			elseif t == channelType.category then
				channel = guild._categories:_insert(d)
			elseif t == channelType.forum then
				channel = guild._forum_channels:_insert(d)
			end
		end
	elseif t == channelType.private then
		channel = client._private_channels:_insert(d)
	elseif t == channelType.group then
		channel = client._group_channels:_insert(d)
	else
		return client:warning('Unhandled CHANNEL_CREATE (type %s)', d.type)
	end
	if channel then
		return client:emit('channelCreate', channel)
	end
end

function EventHandler.CHANNEL_UPDATE(d, client)
	local channel
	local t = d.type
	if t == channelType.text or t == channelType.news or t == channelType.voice or t == channelType.category or t == channelType.forum then
		local guild = client._guilds:get(d.guild_id)
		if not guild then
			local fetchedGuild, err = client._api:getGuild(d.guild_id)
			if fetchedGuild then
				guild = client._guilds:_insert(fetchedGuild)
			else
				return client:warning("Failed to fetch guild %s for CHANNEL_UPDATE: %s", d.guild_id, err)
			end
		end
		if guild then
			if t == channelType.text or t == channelType.news then
				channel = guild._text_channels:_insert(d)
			elseif t == channelType.voice then
				channel = guild._voice_channels:_insert(d)
			elseif t == channelType.category then
				channel = guild._categories:_insert(d)
			elseif t == channelType.forum then
				channel = guild._forum_channels:_insert(d)
			elseif t == channelType.stage then

			end
		end
	elseif t == channelType.private then -- private channels should never update
		channel = client._private_channels:_insert(d)
	elseif t == channelType.group then
		channel = client._group_channels:_insert(d)
	else
		return client:warning('Unhandled CHANNEL_UPDATE (type %s)', d.type)
	end
	if channel then
		return client:emit('channelUpdate', channel)
	end
end

function EventHandler.CHANNEL_DELETE(d, client)
	local channel
	local t = d.type
	if t == channelType.text or t == channelType.news or t == channelType.voice or t == channelType.category or t == channelType.forum then
		local guild = client._guilds:get(d.guild_id)
		if not guild then
			local fetchedGuild, err = client._api:getGuild(d.guild_id)
			if fetchedGuild then
				guild = client._guilds:_insert(fetchedGuild)
			else
				return client:warning("Failed to fetch guild %s for CHANNEL_DELETE: %s", d.guild_id, err)
			end
		end
		if guild then
			if t == channelType.text or t == channelType.news then
				channel = guild._text_channels:_remove(d)
			elseif t == channelType.voice then
				channel = guild._voice_channels:_remove(d)
			elseif t == channelType.category then
				channel = guild._categories:_remove(d)
			elseif t == channelType.forum then
				channel = guild._forum_channels:_remove(d)
			end
		end
	elseif t == channelType.private then
		channel = client._private_channels:_remove(d)
	elseif t == channelType.group then
		channel = client._group_channels:_remove(d)
	else
		return client:warning('Unhandled CHANNEL_DELETE (type %s)', d.type)
	end
	if channel then
		return client:emit('channelDelete', channel)
	end
end

function EventHandler.CHANNEL_RECIPIENT_ADD(d, client)
	local channel = client._group_channels:get(d.channel_id)
	if not channel then
		local fetchedChannel, err = client._api:getChannel(d.channel_id)
		if fetchedChannel then
			channel = client._group_channels:_insert(fetchedChannel)
		else
			return client:warning("Failed to fetch group channel %s for CHANNEL_RECIPIENT_ADD: %s", d.channel_id, err)
		end
	end
	if channel then
		local user = channel._recipients:_insert(d.user)
		return client:emit('recipientAdd', channel, user)
	end
end

function EventHandler.CHANNEL_RECIPIENT_REMOVE(d, client)
	local channel = client._group_channels:get(d.channel_id)
	if not channel then
		local fetchedChannel, err = client._api:getChannel(d.channel_id)
		if fetchedChannel then
			channel = client._group_channels:_insert(fetchedChannel)
		else
			return client:warning("Failed to fetch group channel %s for CHANNEL_RECIPIENT_REMOVE: %s", d.channel_id, err)
		end
	end
	if channel then
		local user = channel._recipients:_remove(d.user)
		return client:emit('recipientRemove', channel, user)
	end
end

function EventHandler.GUILD_CREATE(d, client, shard)
	if client._options.syncGuilds and not d.unavailable and not client._user._bot then
		shard:syncGuilds({d.id})
	end
	local guild = client._guilds:get(d.id)
	if guild then
		if guild._unavailable and not d.unavailable then
			guild:_load(d)
			guild:_makeAvailable(d)
			client:emit('guildAvailable', guild)
		end
		if shard._loading then
			shard._loading.guilds[d.id] = nil
			return checkReady(shard)
		end
	else
		guild = client._guilds:_insert(d)
		return client:emit('guildCreate', guild)
	end
end

function EventHandler.GUILD_UPDATE(d, client)
	local guild = client._guilds:_insert(d)
	return client:emit('guildUpdate', guild)
end

function EventHandler.GUILD_DELETE(d, client)
	if d.unavailable then
		local guild = client._guilds:_insert(d)
		return client:emit('guildUnavailable', guild)
	else
		local guild = client._guilds:_remove(d)
		return client:emit('guildDelete', guild)
	end
end

function EventHandler.GUILD_BAN_ADD(d, client)
	local guild = client._guilds:get(d.guild_id)
	if not guild then
		local fetchedGuild, err = client._api:getGuild(d.guild_id)
		if fetchedGuild then
			guild = client._guilds:_insert(fetchedGuild)
		else
			return client:warning("Failed to fetch guild %s for GUILD_BAN_ADD: %s", d.guild_id, err)
		end
	end
	if guild then
		local user = client._users:_insert(d.user)
		return client:emit('userBan', user, guild)
	end
end

function EventHandler.GUILD_BAN_REMOVE(d, client)
	local guild = client._guilds:get(d.guild_id)
	if not guild then
		local fetchedGuild, err = client._api:getGuild(d.guild_id)
		if fetchedGuild then
			guild = client._guilds:_insert(fetchedGuild)
		else
			return client:warning("Failed to fetch guild %s for GUILD_BAN_REMOVE: %s", d.guild_id, err)
		end
	end
	if guild then
		local user = client._users:_insert(d.user)
		return client:emit('userUnban', user, guild)
	end
end

function EventHandler.GUILD_EMOJIS_UPDATE(d, client)
	local guild = client._guilds:get(d.guild_id)
	if not guild then
		if client._options.suppressUncachedWarning then return end
		return client:warning("Uncached Guild (%s) on GUILD_EMOJIS_UPDATE", d.guild_id)
	end

	if not guild._emojis then
		client:debug("Incomplete guild %s found in cache on GUILD_EMOJIS_UPDATE, fetching from API.", d.guild_id)
		local fullGuildData, err = client._api:getGuild(d.guild_id)
		if fullGuildData then
			guild = client._guilds:_insert(fullGuildData)
		else
			return client:warning("Could not fetch full guild %s to update emojis: %s", d.guild_id, err)
		end
	end

	if guild and guild._emojis then
		guild._emojis:_load(d.emojis, true)
		return client:emit('emojisUpdate', guild)
	end
end

function EventHandler.GUILD_MEMBER_ADD(d, client)
	local guild = client._guilds:get(d.guild_id)
	if not guild then
		local fetchedGuild, err = client._api:getGuild(d.guild_id)
		if fetchedGuild then
			guild = client._guilds:_insert(fetchedGuild)
		else
			return client:warning("Failed to fetch guild %s for GUILD_MEMBER_ADD: %s", d.guild_id, err)
			end
	end
	if guild then
		local member = guild._members:_insert(d)
		guild._member_count = guild._member_count + 1
		return client:emit('memberJoin', member)
	end
end

function EventHandler.GUILD_MEMBER_UPDATE(d, client)
	local guild = client._guilds:get(d.guild_id)
	if not guild then
		local fetchedGuild, err = client._api:getGuild(d.guild_id)
		if fetchedGuild then
			guild = client._guilds:_insert(fetchedGuild)
		else
			return client:warning("Failed to fetch guild %s for GUILD_MEMBER_UPDATE: %s", d.guild_id, err)
		end
	end
	if guild then
		local member = guild._members:_insert(d)
		return client:emit('memberUpdate', member)
	end
end

function EventHandler.GUILD_MEMBER_REMOVE(d, client)
	local guild = client._guilds:get(d.guild_id)
	if not guild then
		local fetchedGuild, err = client._api:getGuild(d.guild_id)
		if fetchedGuild then
			guild = client._guilds:_insert(fetchedGuild)
		else
			return client:warning("Failed to fetch guild %s for GUILD_MEMBER_REMOVE: %s", d.guild_id, err)
		end
	end
	if guild then
		local member = guild._members:_remove(d)
		guild._member_count = guild._member_count - 1
		return client:emit('memberLeave', member)
	end
end

function EventHandler.GUILD_ROLE_CREATE(d, client)
	local guild = client._guilds:get(d.guild_id)
	if not guild then
		local fetchedGuild, err = client._api:getGuild(d.guild_id)
		if fetchedGuild then
			guild = client._guilds:_insert(fetchedGuild)
		else
			return client:warning("Failed to fetch guild %s for GUILD_ROLE_CREATE: %s", d.guild_id, err)
		end
	end
	if guild then
		local role = guild._roles:_insert(d.role)
		return client:emit('roleCreate', role)
	end
end

function EventHandler.GUILD_ROLE_UPDATE(d, client)
	local guild = client._guilds:get(d.guild_id)
	if not guild then
		local fetchedGuild, err = client._api:getGuild(d.guild_id)
		if fetchedGuild then
			guild = client._guilds:_insert(fetchedGuild)
		else
			return client:warning("Failed to fetch guild %s for GUILD_ROLE_UPDATE: %s", d.guild_id, err)
		end
	end
	if guild then
		local role = guild._roles:_insert(d.role)
		return client:emit('roleUpdate', role)
	end
end

function EventHandler.GUILD_ROLE_DELETE(d, client) -- role object not provided
	local guild = client._guilds:get(d.guild_id)
	if not guild then
		local fetchedGuild, err = client._api:getGuild(d.guild_id)
		if fetchedGuild then
			guild = client._guilds:_insert(fetchedGuild)
		else
			return client:warning("Failed to fetch guild %s for GUILD_ROLE_DELETE: %s", d.guild_id, err)
		end
	end
	if guild then
		local role = guild._roles:_delete(d.role_id)
		if not role then return warning(client, 'Role', d.role_id, 'GUILD_ROLE_DELETE') end
		return client:emit('roleDelete', role)
	end
end

function EventHandler.MESSAGE_CREATE(d, client)
	local channel = getChannel(client, d)
	if not channel then return end

	if channel.guild and not channel.guild._members then
		client:debug("Incomplete guild %s found for channel %s, fetching from API.", channel.guild.id, channel.id)
		local fullGuildData, err = client._api:getGuild(channel.guild.id)
		if fullGuildData then
			local updatedGuild = client._guilds:_insert(fullGuildData)
			channel.guild = updatedGuild
			if channel._parent then
				channel._parent.guild = updatedGuild
			end
		else
			client:warning("Could not fetch full guild %s to process message: %s", channel.guild.id, err)
			return 
		end
	end

	if not (channel.type == channelType.text or channel.type == channelType.news or channel.type == channelType.voice or channel.type == channelType.private or channel.type == channelType.group or THREAD_TYPES[channel.type] or channel.type == channelType.forum) then
		return client:warning("Received MESSAGE_CREATE for non-text channel %s (type %s)", d.channel_id, channel.type)
	end

	local message = channel._messages:_insert(d)
	return client:emit('messageCreate', message)
end

function EventHandler.MESSAGE_UPDATE(d, client) -- may not contain the whole message
	local channel = getChannel(client, d)
	if not channel then return end -- getChannel already handles warning

	-- Ensure it's a text-based channel before trying to access _messages
	if not (channel.type == channelType.text or channel.type == channelType.news or channel.type == channelType.voice or channel.type == channelType.private or channel.type == channelType.group or THREAD_TYPES[channel.type] or channel.type == channelType.forum) then
		return client:warning("Received MESSAGE_UPDATE for non-text channel %s (type %s)", d.channel_id, channel.type)
	end

	local message = channel._messages:get(d.id)
	if not message then
		local fetchedMessage, err = client._api:getChannelMessage(d.channel_id, d.id)
		if fetchedMessage then
			message = channel._messages:_insert(fetchedMessage)
		else
			return client:warning("Failed to fetch message %s for MESSAGE_UPDATE: %s", d.id, err)
		end
	end
	
	if message then
		if THREAD_TYPES[channel._type] then
			channel._message_count = (channel._message_count or 0) + 1
			channel._total_message_sent = (channel._total_message_sent or 0) + 1
		end

		message:_setOldContent(d)
		message:_load(d)
		return client:emit('messageUpdate', message)
	end
end

function EventHandler.MESSAGE_DELETE(d, client) -- message object not provided
	local channel = getChannel(client, d)
	if not channel then return end -- getChannel already handles warning

	-- Ensure it's a text-based channel before trying to access _messages
	if not (channel.type == channelType.text or channel.type == channelType.news or channel.type == channelType.voice or channel.type == channelType.private or channel.type == channelType.group or THREAD_TYPES[channel.type] or channel.type == channelType.forum) then
		return client:warning("Received MESSAGE_DELETE for non-text channel %s (type %s)", d.channel_id, channel.type)
	end

	local message = channel._messages:_delete(d.id)
	if message then
		return client:emit('messageDelete', message)
	else
		if not client._options.suppressUncachedWarning then
			client:warning("Message %s not found in cache for MESSAGE_DELETE", d.id)
		end
	end
end

function EventHandler.MESSAGE_DELETE_BULK(d, client)
	local channel = getChannel(client, d)
	if not channel then return end -- getChannel already handles warning

	-- Ensure it's a text-based channel before trying to access _messages
	if not (channel.type == channelType.text or channel.type == channelType.news or channel.type == channelType.voice or channel.type == channelType.private or channel.type == channelType.group or THREAD_TYPES[channel.type] or channel.type == channelType.forum) then
		return client:warning("Received MESSAGE_DELETE_BULK for non-text channel %s (type %s)", d.channel_id, channel.type)
	end

	for _, id in ipairs(d.ids) do
		local message = channel._messages:_delete(id)
		if message then
			if THREAD_TYPES[channel._type] then
				channel._message_count = (channel._message_count or 0) - #d.ids
			end

			client:emit('messageDelete', message)
		else
			if not client._options.suppressUncachedWarning then
				client:warning("Message %s not found in cache for MESSAGE_DELETE_BULK", id)
			end
		end
	end
end

function EventHandler.MESSAGE_REACTION_ADD(d, client)
	local channel = getChannel(client, d)
	if not channel then return end -- getChannel already handles warning

	-- Ensure it's a text-based channel before trying to access _messages
	if not (channel.type == channelType.text or channel.type == channelType.news or channel.type == channelType.voice or channel.type == channelType.private or channel.type == channelType.group or THREAD_TYPES[channel.type] or channel.type == channelType.forum) then
		return client:warning("Received MESSAGE_REACTION_ADD for non-text channel %s (type %s)", d.channel_id, channel.type)
	end

	local k = d.emoji.id ~= null and d.emoji.id or d.emoji.name
	client:emit('reactionAddAny', channel, d.message_id, k, d.user_id)
	local message = channel._messages:get(d.message_id)
	if not message then
		local fetchedMessage, err = client._api:getChannelMessage(d.channel_id, d.message_id)
		if fetchedMessage then
			message = channel._messages:_insert(fetchedMessage)
		else
			return client:warning("Failed to fetch message %s for MESSAGE_REACTION_ADD: %s", d.message_id, err)
		end
	end
	if message then
		local reaction = message:_addReaction(d)
		return client:emit('reactionAdd', reaction, d.user_id)
	end
end

function EventHandler.MESSAGE_REACTION_REMOVE(d, client)
	local channel = getChannel(client, d)
	if not channel then return end -- getChannel already handles warning

	-- Ensure it's a text-based channel before trying to access _messages
	if not (channel.type == channelType.text or channel.type == channelType.news or channel.type == channelType.voice or channel.type == channelType.private or channel.type == channelType.group or THREAD_TYPES[channel.type] or channel.type == channelType.forum) then
		return client:warning("Received MESSAGE_REACTION_REMOVE for non-text channel %s (type %s)", d.channel_id, channel.type)
	end

	local k = d.emoji.id ~= null and d.emoji.id or d.emoji.name
	client:emit('reactionRemoveAny', channel, d.message_id, k, d.user_id)
	local message = channel._messages:get(d.message_id)
	if not message then
		local fetchedMessage, err = client._api:getChannelMessage(d.channel_id, d.message_id)
		if fetchedMessage then
			message = channel._messages:_insert(fetchedMessage)
		else
			return client:warning("Failed to fetch message %s for MESSAGE_REACTION_REMOVE: %s", d.message_id, err)
		end
	end
	if message then
		local reaction = message:_removeReaction(d)
		if not reaction then -- uncached reaction?
			local k = d.emoji.id ~= null and d.emoji.id or d.emoji.name
			return warning(client, 'Reaction', k, 'MESSAGE_REACTION_REMOVE')
		end
		return client:emit('reactionRemove', reaction, d.user_id)
	end
end

function EventHandler.MESSAGE_REACTION_REMOVE_ALL(d, client)
	local channel = getChannel(client, d)
	if not channel then return end -- getChannel already handles warning

	-- Ensure it's a text-based channel before trying to access _messages
	if not (channel.type == channelType.text or channel.type == channelType.news or channel.type == channelType.voice or channel.type == channelType.private or channel.type == channelType.group or THREAD_TYPES[channel.type] or channel.type == channelType.forum) then
		return client:warning("Received MESSAGE_REACTION_REMOVE_ALL for non-text channel %s (type %s)", d.channel_id, channel.type)
	end

	client:emit('reactionRemoveAllAny', channel, d.message_id)
	local message = channel._messages:get(d.message_id)
	if not message then
		local fetchedMessage, err = client._api:getChannelMessage(d.channel_id, d.message_id)
		if fetchedMessage then
			message = channel._messages:_insert(fetchedMessage)
		else
			return client:warning("Failed to fetch message %s for MESSAGE_REACTION_REMOVE_ALL: %s", d.message_id, err)
		end
	end
	if message then
		local reactions = message._reactions
		if reactions then
			for reaction in reactions:iter() do
				reaction._count = 0
			end
			message._reactions = nil
		end
		return client:emit('reactionRemoveAll', message)
	end
end

function EventHandler.CHANNEL_PINS_UPDATE(d, client)
	local channel = getChannel(client, d)
	if not channel then return warning(client, 'TextChannel', d.channel_id, 'CHANNEL_PINS_UPDATE') end
	return client:emit('pinsUpdate', channel)
end

function EventHandler.PRESENCE_UPDATE(d, client) -- may have incomplete data
	local user = client._users:get(d.user.id)
	if not user then
		local fetchedUser, err = client._api:getUser(d.user.id)
		if fetchedUser then
			user = client._users:_insert(fetchedUser)
		else
			return client:warning("Failed to fetch user %s for PRESENCE_UPDATE: %s", d.user.id, err)
		end
	end
	if user then
		user:_load(d.user)
	end

	if d.guild_id then
		local guild = client._guilds:get(d.guild_id)
		if not guild then
			local fetchedGuild, err = client._api:getGuild(d.guild_id)
			if fetchedGuild then
				guild = client._guilds:_insert(fetchedGuild)
			else
				return client:warning("Failed to fetch guild %s for PRESENCE_UPDATE: %s", d.guild_id, err)
			end
		end
		if guild then
			local member
			if client._options.cacheAllMembers then
				member = guild._members:get(d.user.id)
				if not member then
					local fetchedMember, err = client._api:getGuildMember(d.guild_id, d.user.id)
					if fetchedMember then
						member = guild._members:_insert(fetchedMember)
					else
						return client:warning("Failed to fetch member %s for PRESENCE_UPDATE: %s", d.user.id, err)
					end
				end
			else
				if d.status == 'offline' then -- uncache offline members
					member = guild._members:_delete(d.user.id)
				end
			end
			if member then
				member:_loadPresence(d)
				return client:emit('presenceUpdate', member)
			end
		end
	else
		local relationship = client._relationships:get(d.user.id)
		if not relationship then
			-- Relationships are not directly fetchable via API in the same way as guilds/channels/members.
			-- If it's not in cache, it means we don't have a relationship with this user.
			return client:warning("Relationship for user %s not found in cache for PRESENCE_UPDATE", d.user.id)
		end
		if relationship then
			relationship:_loadPresence(d)
			return client:emit('relationshipUpdate', relationship)
		end
	end
end

function EventHandler.RELATIONSHIP_ADD(d, client)
	local relationship = client._relationships:_insert(d)
	return client:emit('relationshipAdd', relationship)
end

function EventHandler.RELATIONSHIP_REMOVE(d, client)
	local relationship = client._relationships:_remove(d)
	return client:emit('relationshipRemove', relationship)
end

function EventHandler.TYPING_START(d, client)
	local channel = getChannel(client, d)
	if not channel then return end -- getChannel already handles warning

	local user = client._users:get(d.user_id)
	if not user then
		local fetchedUser, err = client._api:getUser(d.user_id)
		if fetchedUser then
			user = client._users:_insert(fetchedUser)
		else
			return client:warning("Failed to fetch user %s for TYPING_START: %s", d.user_id, err)
		end
	end

	if user then
		return client:emit('typingStart', user, channel, d.timestamp)
	end
end

function EventHandler.USER_UPDATE(d, client)
	client._user:_load(d)
	return client:emit('userUpdate', client._user)
end

local function load(obj, d)
	for k, v in pairs(d) do obj[k] = v end
end

function EventHandler.VOICE_STATE_UPDATE(d, client)
	local guild = client._guilds:get(d.guild_id)
	if not guild then
		local fetchedGuild, err = client._api:getGuild(d.guild_id)
		if fetchedGuild then
			guild = client._guilds:_insert(fetchedGuild)
		else
			return client:warning("Failed to fetch guild %s for VOICE_STATE_UPDATE: %s", d.guild_id, err)
		end
	end

	if not guild then return end -- If guild is still nil after fetch attempt, stop.

	local member = guild._members:get(d.user_id)
	if not member and d.member then -- Try to insert if provided in payload
		member = guild._members:_insert(d.member)
	end

	if not member then -- If member is still not cached, try to fetch it
		local fetchedMember, err = client._api:getGuildMember(d.guild_id, d.user_id)
		if fetchedMember then
			member = guild._members:_insert(fetchedMember)
		else
			return client:warning("Failed to fetch member %s for VOICE_STATE_UPDATE: %s", d.user_id, err)
		end
	end

	if not member then return end -- If member is still nil after fetch attempt, stop.

	local states = guild._voice_states
	local channels = guild._voice_channels
	local new_channel_id = Resolver.channelId(d.channel_id)
	local state = states[d.user_id]

	if state then -- user is already connected
		local old_channel_id = Resolver.channelId(state.channel_id)
		load(state, d)
		if new_channel_id ~= null then -- state changed, but user has not disconnected
			if new_channel_id == old_channel_id then -- user did not change channels
				client:emit('voiceUpdate', member)
			else -- user changed channels
				local old_channel = channels:get(old_channel_id)
				if not old_channel and old_channel_id then -- Only try to fetch if old_channel_id is valid
					local fetchedChannel, err = client._api:getChannel(old_channel_id)
					if fetchedChannel then
						old_channel = channels:_insert(fetchedChannel)
					else
						client:warning("Failed to fetch old voice channel %s for VOICE_STATE_UPDATE: %s", old_channel_id, err)
					end
				end

				local new_channel = channels:get(new_channel_id)
				if not new_channel and new_channel_id then -- Only try to fetch if new_channel_id is valid
					local fetchedChannel, err = client._api:getChannel(new_channel_id)
					if fetchedChannel then
						new_channel = channels:_insert(fetchedChannel)
					else
						client:warning("Failed to fetch new voice channel %s for VOICE_STATE_UPDATE: %s", new_channel_id, err)
					end
				end

				if d.user_id == client._user._id then -- move connection to new channel
					local connection = old_channel and old_channel._connection
					if connection and new_channel then
						new_channel._connection = connection
						if old_channel then old_channel._connection = nil end
						connection._channel = new_channel
						connection:_continue(true)
					end
				end

				if old_channel then client:emit('voiceChannelLeave', member, old_channel) end
				if new_channel then client:emit('voiceChannelJoin', member, new_channel) end
			end
		else -- user has disconnected
			states[d.user_id] = nil
			local old_channel = channels:get(old_channel_id)
			if not old_channel and old_channel_id then -- Only try to fetch if old_channel_id is valid
				local fetchedChannel, err = client._api:getChannel(old_channel_id)
				if fetchedChannel then
					old_channel = channels:_insert(fetchedChannel)
				else
					client:warning("Failed to fetch old voice channel %s for VOICE_STATE_UPDATE (disconnect): %s", old_channel_id, err)
				end
			end
			if old_channel then client:emit('voiceChannelLeave', member, old_channel) end
			client:emit('voiceDisconnect', member)
		end
	else -- user has connected
		states[d.user_id] = d
		local new_channel = channels:get(new_channel_id)
		if not new_channel and new_channel_id then -- Only try to fetch if new_channel_id is valid
			local fetchedChannel, err = client._api:getChannel(new_channel_id)
			if fetchedChannel then
				new_channel = channels:_insert(fetchedChannel)
			else
				return client:warning("Failed to fetch new voice channel %s for VOICE_STATE_UPDATE (connect): %s", new_channel_id, err)
			end
		end
		if new_channel then
			client:emit('voiceConnect', member)
			client:emit('voiceChannelJoin', member, new_channel)
		end
	end
end

function EventHandler.VOICE_SERVER_UPDATE(d, client)
	local guild = client._guilds:get(d.guild_id)
	if not guild then
		local fetchedGuild, err = client._api:getGuild(d.guild_id)
		if fetchedGuild then
			guild = client._guilds:_insert(fetchedGuild)
		else
			return client:warning("Failed to fetch guild %s for VOICE_SERVER_UPDATE: %s", d.guild_id, err)
		end
	end

	if not guild then return end -- If guild is still nil after fetch attempt, stop.

	local state = guild._voice_states[client._user._id]
	if not state then return client:warning('Voice state not initialized before VOICE_SERVER_UPDATE') end
	load(state, d)

	local channel = guild._voice_channels:get(Resolver.channelId(state.channel_id))
	if not channel then
		local fetchedChannel, err = client._api:getChannel(state.channel_id)
		if fetchedChannel then
			channel = guild._voice_channels:_insert(fetchedChannel)
		else
			return client:warning("Failed to fetch voice channel %s for VOICE_SERVER_UPDATE: %s", state.channel_id, err)
		end
	end

	if not channel then return end -- If channel is still nil after fetch attempt, stop.

	local connection = channel._connection
	if not connection then return client:warning('Voice connection not initialized before VOICE_SERVER_UPDATE') end
	return client._voice:_prepareConnection(state, connection)
end

function EventHandler.WEBHOOKS_UPDATE(d, client) -- webhook object is not provided
	local guild = client._guilds:get(d.guild_id)
	if not guild then
		local fetchedGuild, err = client._api:getGuild(d.guild_id)
		if fetchedGuild then
			guild = client._guilds:_insert(fetchedGuild)
		else
			return client:warning("Failed to fetch guild %s for WEBHOOKS_UPDATE: %s", d.guild_id, err)
		end
	end

	if not guild then return end -- If guild is still nil after fetch attempt, stop.

	local channel = guild._text_channels:get(d.channel_id)
	if not channel then
		local fetchedChannel, err = client._api:getChannel(d.channel_id)
		if fetchedChannel then
			channel = guild._text_channels:_insert(fetchedChannel)
		else
			return client:warning("Failed to fetch text channel %s for WEBHOOKS_UPDATE: %s", d.channel_id, err)
		end
	end

	if channel then
		return client:emit('webhooksUpdate', channel)
	end
end

function EventHandler.AUTO_MODERATION_RULE_CREATE(d, client)
end

function EventHandler.AUTO_MODERATION_RULE_UPDATE(d, client)
end

function EventHandler.AUTO_MODERATION_RULE_DELETE(d, client)
end

function EventHandler.AUTO_MODERATION_ACTION_EXECUTION(d, client)
end

function EventHandler.THREAD_CREATE(d, client)
	local parent_channel = getChannel(client, {channel_id = d.parent_id})
	if not parent_channel then return end
	local channel = parent_channel._thread_channels:_insert(d, parent_channel)
	return client:emit('threadCreate', channel, d.newly_created)
end

function EventHandler.THREAD_UPDATE(d, client)
	local parent_channel = getChannel(client, {channel_id = d.parent_id})
	if not parent_channel then return end
	local channel = parent_channel._thread_channels:_insert(d, parent_channel)
	return client:emit('threadUpdate', channel)
end

function EventHandler.THREAD_DELETE(d, client)
	local parent_channel = getChannel(client, {channel_id = d.parent_id})
	if not parent_channel then return end
	if not d.thread_metadata then
		return client:emit('threadDeleteUncached', d, parent_channel)
	end
	local channel = parent_channel._thread_channels:_remove(d)
	return client:emit('threadDelete', channel)
end

local function clearStaleThreads(threads)
	for thread in threads:iter() do
		if thread._thread_metadata.archived then
			threads:_delete(thread.id)
		end
	end
end

function EventHandler.THREAD_LIST_SYNC(d, client)
	local guild = client._guilds:get(d.guild_id)
	if not guild then return warning(client, 'Guild', d.guild_id, 'THREAD_LIST_SYNC') end
	local synchedThreads = {}
	if d.channel_ids then
		for _, channel_id in ipairs(d.channel_ids) do
			local channel = getChannel(client, {channel_id = channel_id})
			if channel then
				clearStaleThreads(channel._thread_channels)
			end
		end
	else
		clearStaleThreads(guild._thread_channels)
	end
	for _, data in ipairs(d.threads) do
		local channel = getChannel(client, {channel_id = data.parent_id})
		if channel then
			insert(synchedThreads, channel._thread_channels:_insert(data, channel))
		end
	end
	for _, data in ipairs(d.members) do
		local thread = getChannel(client, {channel_id = data.id})
		if thread then
			thread._members:_insert(data)
		end
	end
	return client:emit('threadListSync', synchedThreads, guild)
end

function EventHandler.THREAD_MEMBER_UPDATE(d, client)
	local thread = getChannel(client, {channel_id = d.id})
	if not thread then return end
	local member = thread._members:_insert(d)
	return client:emit('threadMemberUpdate', member)
end

function EventHandler.THREAD_MEMBERS_UPDATE(d, client)
	local thread = getChannel(client, {channel_id = d.id})
	if not thread then return end
	thread._member_count = d.member_count
	if d.added_members then
		thread._members:_load(d.added_members)
	end
	if d.removed_member_ids then
		for _, id in ipairs(d.removed_member_ids) do
			thread._members:_delete(id)
		end
	end
	return client:emit('threadMembersUpdate', thread)
end

function EventHandler.GUILD_STICKERS_UPDATE(d, client)
end

function EventHandler.GUILD_SCHEDULED_EVENT_CREATE(d, client)
end

function EventHandler.GUILD_SCHEDULED_EVENT_UPDATE(d, client)
end

function EventHandler.GUILD_SCHEDULED_EVENT_DELETE(d, client)
end

function EventHandler.GUILD_SCHEDULED_EVENT_USER_ADD(d, client)
end

function EventHandler.GUILD_SCHEDULED_EVENT_USER_REMOVE(d, client)
end

function EventHandler.STAGE_INSTANCE_CREATE(d, client)
end

function EventHandler.STAGE_INSTANCE_UPDATE(d, client)
end

function EventHandler.STAGE_INSTANCE_DELETE(d, client)
end

function EventHandler.GUILD_AUDIT_LOG_ENTRY_CREATE(d, client)
	return client:emit("guildAuditLogEntryCreate", d)
end

function EventHandler.INTERACTION_CREATE(d, client)
end

return EventHandler