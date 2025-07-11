local VoiceSocket = require('voice/VoiceSocket')
local Emitter = require('utils/Emitter')

local opus = require('voice/opus') or {}
local sodium = require('voice/sodium') or {}
local constants = require('constants')

local wrap = coroutine.wrap
local format = string.format

local GATEWAY_VERSION_VOICE = constants.GATEWAY_VERSION_VOICE

local VoiceManager = require('class')('VoiceManager', Emitter)

function VoiceManager:__init(client)
	Emitter.__init(self)
	self._client = client
end

function VoiceManager:_prepareConnection(state, connection)
	if not next(opus) then
		return self._client:error('Cannot prepare voice connection: libopus not found')
	end
	if not next(sodium) then
		return self._client:error('Cannot prepare voice connection: libsodium not found')
	end
	local url
	local host, port = string.match(state.endpoint, "(.+):(%d+)$")
	if host and port then
		url = format("wss://%s:%s", host, port)
	else
		url = format("wss://%s", state.endpoint)
	end
	local socket = VoiceSocket(state, connection, self)
	local path = format('/?v=%i', GATEWAY_VERSION_VOICE)
	return wrap(socket.connect)(socket, url, path)
end

return VoiceManager