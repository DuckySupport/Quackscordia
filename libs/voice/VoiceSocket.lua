local uv = require('uv')
local class = require('class')
local timer = require('timer')
local enums = require('enums')
local sodium = require('voice/sodium') or {}

local WebSocket = require('client/WebSocket')
local Stopwatch = require('utils/Stopwatch')

local logLevel = assert(enums.logLevel)
local format = string.format
local setInterval, clearInterval = timer.setInterval, timer.clearInterval
local wrap = coroutine.wrap
local os_time = os.time -- Use os_time to avoid conflicts with 'time' local variable
local unpack, pack = string.unpack, string.pack -- luacheck: ignore

local SUPPORTED_ENCRYPTION_MODES = { 'aead_xchacha20_poly1305_rtpsize' }
if sodium.aead_aes256_gcm then -- AEAD AES256-GCM is only available if the hardware supports it
    table.insert(SUPPORTED_ENCRYPTION_MODES, 1, 'aead_aes256_gcm_rtpsize')
end

local IDENTIFY          = 0
local SELECT_PROTOCOL   = 1
local READY             = 2
local HEARTBEAT         = 3
local DESCRIPTION       = 4
local SPEAKING          = 5
local HEARTBEAT_ACK     = 6
local RESUME            = 7
local HELLO             = 8
local RESUMED           = 9

local function checkMode(modes)
    for _, ENCRYPTION_MODE in ipairs(SUPPORTED_ENCRYPTION_MODES) do
        for _, mode in ipairs(modes) do
            if mode == ENCRYPTION_MODE then
                return mode
            end
        end
    end
    return nil -- Explicitly return nil if no mode is found
end

local VoiceSocket = class('VoiceSocket', WebSocket)

-- Enhanced logging functions
for name in pairs(logLevel) do
    VoiceSocket[name] = function(self, fmt, ...)
        local client = self._client
        -- Prepend VoiceSocket context to log messages
        return client[name](client, format('[VoiceSocket] %s', fmt), ...)
    end
end

function VoiceSocket:__init(state, connection, manager)
    WebSocket.__init(self, manager)
    self._state = state
    self._manager = manager
    self._client = manager._client
    self._connection = connection
    self._session_id = state.session_id
    self._seq_ack = -1
    self._sw = Stopwatch() -- Initialize stopwatch for heartbeat timing

    self:debug('VoiceSocket initialized with: session_id=%s, guild_id=%s, user_id=%s, token_present=%s',
        self._session_id, state.guild_id, state.user_id, tostring(state.token ~= nil))
end

function VoiceSocket:handleDisconnect()
    self:info('VoiceSocket handleDisconnect called. Cleaning up connection.')
    -- TODO: reconnecting and resuming - This is where your reconnection logic would go.
    self._connection:_cleanup()
    self:stopHeartbeat() -- Ensure heartbeat is stopped on disconnect
end

function VoiceSocket:handlePayload(payload)
    local manager = self._manager
    local d = payload.d
    local op = payload.op

    self:debug('Received WebSocket OP %s. Payload: %s', op, json.encode(payload)) -- Log full payload for debugging

    if payload.s then -- Discord uses 's' for sequence number, not 'seq'
        self._seq_ack = payload.s
        self:debug('Updated _seq_ack to %d from payload.s', self._seq_ack)
    elseif payload.seq then -- Fallback for 'seq' if 's' is not present
        self._seq_ack = payload.seq
        self:debug('Updated _seq_ack to %d from payload.seq (deprecated)', self._seq_ack)
    end


    if op == HELLO then
        self:info('Received HELLO. Heartbeat interval: %dms', d.heartbeat_interval)
        self:startHeartbeat(d.heartbeat_interval)
        self:identify()

    elseif op == READY then
        self:info('Received READY. Data: %s', json.encode(d))
        local mode = checkMode(d.modes)
        if mode then
            self:debug('Selected encryption mode %q from available modes: %s', mode, json.encode(d.modes))
            self._mode = mode
            self._ssrc = d.ssrc
            self:handshake(d.ip, d.port)
        else
            self:error('No supported encryption mode available. Offered modes: %s. Supported: %s',
                json.encode(d.modes), json.encode(SUPPORTED_ENCRYPTION_MODES))
            self:disconnect()
        end

    elseif op == RESUMED then
        self:info('Received RESUMED. Session successfully resumed.')

    elseif op == DESCRIPTION then
        self:info('Received DESCRIPTION. Data: %s', json.encode(d))
        if d.mode == self._mode then
            self:debug('Encryption mode %q matches selected mode.', self._mode)
            self._connection:_prepare(d.secret_key, self)
        else
            self:error('Mismatched encryption mode. Server mode: %q, Client mode: %q', d.mode, self._mode)
            self:disconnect()
        end

    elseif op == HEARTBEAT_ACK then
        self:debug('Received HEARTBEAT_ACK. Latency: %dms', self._sw.milliseconds)
        manager:emit('heartbeat', nil, self._sw.milliseconds) -- TODO: id

    elseif op == SPEAKING then
        self:debug('Received SPEAKING OP. SSRC: %d, User ID: %s, Speaking: %s', d.ssrc, d.user_id, tostring(d.speaking))
        return -- TODO: Implement speaking event handling

    elseif op == 12 then -- Voice Session Disconnect (Client reports disconnect)
        self:info('Received OP 12 (Voice Session Disconnect). User ID: %s, Guild ID: %s, Session ID: %s',
            d.user_id, d.guild_id, d.session_id)
        return

    elseif op == 13 then -- Voice Client Disconnect (Server reports disconnect)
        self:info('Received OP 13 (Voice Client Disconnect). User ID: %s, Guild ID: %s',
            d.user_id, d.guild_id)
        return

    elseif op then
        self:warning('Unhandled WebSocket payload OP %i. Full payload: %s', op, json.encode(payload))
    end
end

local function loop(self)
    return wrap(self.heartbeat)(self)
end

function VoiceSocket:startHeartbeat(interval)
    if self._heartbeat then
        clearInterval(self._heartbeat)
        self:debug('Cleared existing heartbeat interval.')
    end
    self:info('Starting heartbeat with interval %dms', interval)
    self._heartbeat = setInterval(interval, loop, self)
end

function VoiceSocket:stopHeartbeat()
    if self._heartbeat then
        clearInterval(self._heartbeat)
        self:info('Stopped heartbeat.')
    end
    self._heartbeat = nil
end

function VoiceSocket:heartbeat()
    self._sw:reset()
    self:debug('Sending HEARTBEAT. seq_ack: %d, time: %d', self._seq_ack, os_time())
    return self:_send(HEARTBEAT, {
        t = os_time(),
        seq_ack = self._seq_ack,
    })
end

function VoiceSocket:identify()
    local state = self._state
    self:info('Sending IDENTIFY payload...')
    self:debug('IDENTIFY data: { server_id=%s, user_id=%s, session_id=%s, token_present=%s }',
        state.guild_id, state.user_id, state.session_id, tostring(state.token ~= nil))
    return self:_send(IDENTIFY, {
        server_id = state.guild_id,
        user_id = state.user_id,
        session_id = state.session_id,
        token = state.token,
    }, true)
end

function VoiceSocket:resume()
    local state = self._state
    self:info('Sending RESUME payload...')
    self:debug('RESUME data: { server_id=%s, session_id=%s, token_present=%s, seq_ack=%d }',
        state.guild_id, state.session_id, tostring(state.token ~= nil), self._seq_ack)
    return self:_send(RESUME, {
        server_id = state.guild_id,
        session_id = state.session_id,
        token = state.token,
        seq_ack = self._seq_ack,
    })
end

function VoiceSocket:handshake(server_ip, server_port)
    self:info('Starting UDP handshake with server_ip=%s, server_port=%d', server_ip, server_port)
    local udp = uv.new_udp()
    self._udp = udp
    self._ip = server_ip
    self._port = server_port

    udp:recv_start(function(err, data)
        if err then
            self:error('UDP recv_start error: %s', err)
            udp:close() -- Close the UDP handle on error
            return
        end
        udp:recv_stop()
        self:debug('Received UDP handshake response (%d bytes).', #data)
        -- The Discord voice UDP handshake response has a fixed format:
        -- First 4 bytes are unknown, next 70 bytes are the IP address string (null-terminated)
        -- Last 2 bytes are the port (little-endian unsigned short)
        local client_ip = unpack('x4z', data, 5) -- Skip 4 unknown bytes, then unpack null-terminated string
        local client_port = unpack('<I2', data, #data - 1) -- Unpack 2 bytes from end (little-endian)

        self:info('UDP Handshake: Discovered client_ip=%q, client_port=%d', client_ip, client_port)
        return wrap(self.selectProtocol)(self, client_ip, client_port)
    end)

    -- UDP Discovery Packet (Discord Voice requires a specific format)
    -- 0x1: Type (Always 0x1 for IP Discovery)
    -- 70: Length of IP string (fixed for IPv4)
    -- SSRC: Your SSRC
    -- IP: (Placeholder, 0-filled, will be filled by server)
    -- Port: (Placeholder, 0-filled, will be filled by server)
    -- The server will fill in your external IP and port in the response.
    local packet = pack('>I2I2I4c64H', 0x1, 70, self._ssrc, string.rep('\0', 64), 0) -- 64 bytes for IP, 2 bytes for port
    self:debug('Sending UDP handshake packet to %s:%d. Packet length: %d bytes. SSRC: %d', server_ip, server_port, #packet, self._ssrc)
    self:debug('Raw UDP packet sent (first 10 bytes): %s', string.sub(packet, 1, 10):gsub('.', function(c) return format('%02X ', string.byte(c)) end))

    return udp:send(packet, server_ip, server_port)
end

function VoiceSocket:selectProtocol(address, port)
    self:info('Sending SELECT_PROTOCOL payload. Address: %s, Port: %d, Mode: %s', address, port, self._mode)
    return self:_send(SELECT_PROTOCOL, {
        protocol = 'udp',
        data = {
            address = address,
            port = port,
            mode = self._mode,
        }
    })
end

function VoiceSocket:setSpeaking(speaking)
    self:debug('Sending SPEAKING payload. Speaking: %s, SSRC: %d', tostring(speaking), self._ssrc)
    return self:_send(SPEAKING, {
        speaking = speaking,
        delay = 0,
        ssrc = self._ssrc,
    })
end

return VoiceSocket