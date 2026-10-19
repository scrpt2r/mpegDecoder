--!native
--!optimize 2

--// Libs
local libs = script.Parent
local constants = require(libs.constants)
local bitReader = require(libs.bitReader)
local types = require(libs.global.types)

--// Types
type packet = types.packet
type demuxer = types.demuxer

--// Lib Decleration
local demuxer = {}

--// Lib Public Functions
function demuxer.new(data: buffer): demuxer
	return {
		buf = bitReader.new(data),
		startCode = -1,

		hasPackHeader = false,
		hasSystemHeader = false,
		hasHeaders = false,

		sysClockRef = 0,
		lastDecodedPts = 0,

		numAudioStreams = 0,
		numVideoStreams = 0,

		currentPacket = { type = 0, pts = 0, data = buffer.create(0), length = 0 },
		nextPacket = { type = 0, pts = 0, data = buffer.create(0), length = 0 },
	} :: demuxer
end

function demuxer.decodeTime(self: demuxer): number
	local clock = bit32.lshift(bitReader.read(self.buf, 3), 30)
	bitReader.skip(self.buf, 1)

	clock = bit32.bor(clock, bit32.lshift(bitReader.read(self.buf, 15), 15))
	bitReader.skip(self.buf, 1)

	clock = bit32.bor(clock, bitReader.read(self.buf, 15))
	bitReader.skip(self.buf, 1)

	return clock / 90000.0
end

function demuxer.hasHeaders(self: demuxer): boolean
	if self.hasHeaders then
		return true
	end

	if not self.hasPackHeader then
		if self.startCode ~= constants.START.PACK and bitReader.findStartCode(self.buf, constants.START.PACK) == -1 then
			return false
		end

		self.startCode = constants.START.PACK
		if not bitReader.has(self.buf, 64) then
			return false
		end

		self.startCode = -1

		if bitReader.read(self.buf, 4) ~= 0x02 then
			return false
		end

		self.sysClockRef = demuxer.decodeTime(self)
		bitReader.skip(self.buf, 1)
		bitReader.skip(self.buf, 22)
		bitReader.skip(self.buf, 1)

		self.hasPackHeader = true
	end

	if not self.hasSystemHeader then
		if
			self.startCode ~= constants.START.SYSTEM
			and bitReader.findStartCode(self.buf, constants.START.SYSTEM) == -1
		then
			return false
		end

		self.startCode = constants.START.SYSTEM
		if not bitReader.has(self.buf, 56) then
			return false
		end

		self.startCode = -1

		bitReader.skip(self.buf, 16)
		bitReader.skip(self.buf, 24)
		self.numAudioStreams = bitReader.read(self.buf, 6)
		bitReader.skip(self.buf, 5)
		self.numVideoStreams = bitReader.read(self.buf, 5)

		self.hasSystemHeader = true
	end

	self.hasHeaders = true

	return true
end

function demuxer.packet(self: demuxer): packet?
	if not bitReader.has(self.buf, bit32.lshift(self.nextPacket.length, 3)) then
		return nil
	end

	local index = bit32.rshift(self.buf.index, 3)
	local dataSlice = buffer.create(self.nextPacket.length)

	buffer.copy(dataSlice, 0, self.buf.bytes, index, self.nextPacket.length)
	self.currentPacket.data = dataSlice
	self.currentPacket.type = self.nextPacket.type
	self.currentPacket.pts = self.nextPacket.pts

	self.currentPacket.length = self.nextPacket.length
	self.nextPacket.length = 0

	return self.currentPacket
end

function demuxer.decodePacket(self: demuxer, typ: number): packet?
	if not bitReader.has(self.buf, bit32.lshift(16, 3)) then
		return nil
	end

	self.startCode = -1

	self.nextPacket.type = typ
	self.nextPacket.length = bitReader.read(self.buf, 16)
	self.nextPacket.length -= bitReader.skipBytes(self.buf, 0xff)

	if bitReader.read(self.buf, 2) == 0x01 then
		bitReader.skip(self.buf, 16)
		self.nextPacket.length -= 2
	end

	local ptsMarker = bitReader.read(self.buf, 2)
	if ptsMarker == 0x03 then
		self.nextPacket.pts = demuxer.decodeTime(self)
		self.lastDecodedPts = self.nextPacket.pts

		bitReader.skip(self.buf, 40)

		self.nextPacket.length -= 10
	elseif ptsMarker == 0x02 then
		self.nextPacket.pts = demuxer.decodeTime(self)
		self.lastDecodedPts = self.nextPacket.pts
		self.nextPacket.length -= 5
	elseif ptsMarker == 0x00 then
		self.nextPacket.pts = constants.DEMUXER.INVALID_TS

		bitReader.skip(self.buf, 4)

		self.nextPacket.length -= 1
	else
		return nil
	end

	return demuxer.packet(self)
end

function demuxer.decode(self: demuxer): packet?
	if not demuxer.hasHeaders(self) then
		return nil
	end

	if self.currentPacket.length ~= 0 then
		local bitsTillNextPacket = self.currentPacket.length

		if not bitReader.has(self.buf, bitsTillNextPacket) then
			return nil
		end

		bitReader.skip(self.buf, bitsTillNextPacket)
		self.currentPacket.length = 0
	end

	if self.nextPacket.length ~= 0 then
		return demuxer.packet(self)
	end

	if self.startCode ~= -1 then
		return demuxer.decodePacket(self, self.startCode)
	end

	while true do
		self.startCode = bitReader.findNextStartCode(self.buf)

		if
			self.startCode == constants.DEMUXER.VIDEO_1
			or self.startCode == constants.DEMUXER.PRIVATE
			or (self.startCode >= constants.DEMUXER.AUDIO_1 and self.startCode <= constants.DEMUXER.AUDIO_4)
		then
			return demuxer.decodePacket(self, self.startCode)
		end

		if self.startCode == -1 then
			break
		end
	end

	return nil
end

return demuxer
