--!native
--!optimize 2

--// Libs
local types = require(script.Parent.global.types)

--// Types
type bitReader = types.bitReader

--// Lib Decleration
local reader = {}

--// Lib Public Functions
function reader.new(data: buffer): bitReader
	return {
		index = 0,
		byteLength = buffer.len(data),
		bytes = data,
	} :: bitReader
end

function reader.peek(self: bitReader, count: number): number
	local offset = self.index
	local value = 0

	while count > 0 do
		local currentByte = buffer.readu8(self.bytes, bit32.rshift(offset, 3))
		local remaining = 8 - bit32.band(offset, 7)
		local read = remaining < count and remaining or count
		local shift = remaining - read
		local mask = bit32.rshift(0xff, (8 - read))

		value = bit32.bor(
			bit32.lshift(value, read),
			bit32.rshift(bit32.band(currentByte, bit32.lshift(mask, shift)), shift)
		)

		offset += read
		count -= read
	end

	return value
end

function reader.has(self: bitReader, count: number): boolean
	return (bit32.lshift(self.byteLength, 3) - self.index) >= count
end

function reader.read(self: bitReader, count: number): number
	local value = reader.peek(self, count)

	self.index += count

	return value
end

function reader.skip(self: bitReader, count: number): number
	self.index += count
	return self.index
end

function reader.rewind(self: bitReader, count: number)
	self.index = math.max(self.index - count, 0)
end

function reader.skipBytes(self: bitReader, value: number): number
	local count = 0

	while reader.has(self, 8) and reader.peek(self, 8) == value do
		reader.skip(self, 8)
		count += 1
	end

	return count
end

function reader.nextBytesAreStartCode(self: bitReader): boolean
	local i = bit32.rshift(self.index + 7, 3)

	return i >= self.byteLength
		or (
			buffer.readu8(self.bytes, i) == 0x00
			and buffer.readu8(self.bytes, i + 1) == 0x00
			and buffer.readu8(self.bytes, i + 2) == 0x01
		)
end

function reader.findNextStartCode(self: bitReader): number
	for i = bit32.rshift(self.index + 7, 3), self.byteLength - 4 do
		if
			buffer.readu8(self.bytes, i) == 0x00
			and buffer.readu8(self.bytes, i + 1) == 0x00
			and buffer.readu8(self.bytes, i + 2) == 0x01
		then
			self.index = bit32.lshift(i + 4, 3)
			return buffer.readu8(self.bytes, i + 3)
		end
	end

	self.index = bit32.lshift(self.byteLength, 3)
	return -1
end

function reader.findStartCode(self: bitReader, code: number): number
	local current = 0

	while true do
		current = reader.findNextStartCode(self)

		if current == code or current == -1 then
			return current
		end
	end

	return -1
end

return reader
