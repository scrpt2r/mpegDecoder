--!native
--!optimize 2

--// Libs
local libs = script.libs
local constants = require(libs.constants)
local bitReader = require(libs.bitReader)
local types = require(libs.global.types)

--// Types
type mpeg = types.mpeg

--// Lib Decleration
local mpeg = {}

--// Lib Public Functions
function mpeg.new(data: buffer): mpeg
	return {
		bits = bitReader.new(data),

		width = 0,
		height = 0,
		frameRate = 0,
		currentFrame = 0,

		hasSequenceHeader = false,

		customIntraQuantMatrix = {},
		customNonIntraQuantMatrix = {},

		intraQuantMatrix = {},
		nonIntraQuantMatrix = {},

		mbWidth = 0,
		mbHeight = 0,
		mbSize = 0,

		codedWidth = 0,
		codedHeight = 0,
		codedSize = 0,

		halfWidth = 0,
		halfHeight = 0,

		currentY = buffer.create(0),
		currentCr = buffer.create(0),
		currentCb = buffer.create(0),

		forwardY = buffer.create(0),
		forwardCr = buffer.create(0),
		forwardCb = buffer.create(0),

		pictureType = 0,
		fullPelForward = false,

		forwardFCode = 0,
		forwardRSize = 0,
		forwardF = 0,

		quantizerScale = 0,
		sliceBegin = false,

		macroblockAddress = 0,
		mbRow = 0,
		mbCol = 0,

		macroblockType = 0,
		macroblockIntra = false,
		macroblockMotFw = false,

		motionFwH = 0,
		motionFwV = 0,
		motionFwHPrev = 0,
		motionFwVPrev = 0,

		dcPredictorY = 0,
		dcPredictorCr = 0,
		dcPredictorCb = 0,

		blockData = table.create(64, 0),
	} :: mpeg
end

function mpeg.initBuffers(self: mpeg)
	self.intraQuantMatrix = constants.DEFAULT_INTRA_QUANT_MATRIX
	self.nonIntraQuantMatrix = constants.DEFAULT_NON_INTRA_QUANT_MATRIX

	self.mbWidth = bit32.rshift(self.width + 15, 4)
	self.mbHeight = bit32.rshift(self.height + 15, 4)
	self.mbSize = self.mbWidth * self.mbHeight

	self.codedWidth = bit32.lshift(self.mbWidth, 4)
	self.codedHeight = bit32.lshift(self.mbHeight, 4)
	self.codedSize = self.codedWidth * self.codedHeight

	self.halfWidth = bit32.lshift(self.mbWidth, 3)
	self.halfHeight = bit32.lshift(self.mbHeight, 3)

	self.currentY = buffer.create(self.codedSize)
	self.currentCr = buffer.create(bit32.rshift(self.codedSize, 2))
	self.currentCb = buffer.create(bit32.rshift(self.codedSize, 2))

	self.forwardY = buffer.create(self.codedSize)
	self.forwardCr = buffer.create(bit32.rshift(self.codedSize, 2))
	self.forwardCb = buffer.create(bit32.rshift(self.codedSize, 2))
end

function mpeg.decodeSequenceHeader(self: mpeg)
	local newWidth = bitReader.read(self.bits, 12)
	local newHeight = bitReader.read(self.bits, 12)

	bitReader.skip(self.bits, 4)

	self.frameRate = constants.PICTURE_RATE[bitReader.read(self.bits, 4)]

	bitReader.skip(self.bits, 18 + 1 + 10 + 1)

	if newWidth ~= self.width or newHeight ~= self.height then
		self.width = newWidth
		self.height = newHeight

		mpeg.initBuffers(self)
	end

	if bitReader.read(self.bits, 1) == 1 then
		for i = 1, 64 do
			local idx = constants.ZIG_ZAG[i] + 1
			self.customIntraQuantMatrix[idx] = bitReader.read(self.bits, 8)
		end

		self.intraQuantMatrix = self.customIntraQuantMatrix
	end

	if bitReader.read(self.bits, 1) == 1 then
		for i = 1, 64 do
			local idx = constants.ZIG_ZAG[i] + 1
			self.customNonIntraQuantMatrix[idx] = bitReader.read(self.bits, 8)
		end

		self.nonIntraQuantMatrix = self.customNonIntraQuantMatrix
	end

	self.hasSequenceHeader = true
end

function mpeg.readHuffman(self: mpeg, codeTable: { number })
	local state = 0

	repeat
		state = codeTable[state + bitReader.read(self.bits, 1) + 1]
	until state < 0 or codeTable[state + 1] == 0

	return codeTable[state + 3]
end

function mpeg.copyMacroblock(self: mpeg, motionH: number, motionV: number, sY: buffer, sCr: buffer, sCb: buffer)
	--stylua: ignore
	local width, scan,
		  H, V, oddH, oddV,
		  src, dest, last

	local dY = self.currentY
	local dCb = self.currentCb
	local dCr = self.currentCr

	width = self.codedWidth
	scan = width - 16

	H = motionH // 2
	V = motionV // 2
	oddH = (bit32.band(motionH, 1) == 1)
	oddV = (bit32.band(motionV, 1) == 1)

	src = (bit32.lshift(self.mbRow, 4) + V) * width + bit32.lshift(self.mbCol, 4) + H
	dest = bit32.lshift(self.mbRow * width + self.mbCol, 4)
	last = dest + bit32.lshift(width, 4)

	local y1, y2, y
	if oddH then
		if oddV then
			while dest < last do
				y1 = buffer.readu8(sY, src) + buffer.readu8(sY, src + width)
				src += 1

				for x = 0, 3 do
					y2 = buffer.readu8(sY, src) + buffer.readu8(sY, src + width)
					src += 1

					y = bit32.band(bit32.rshift(y1 + y2 + 2, 2), 0xff)

					y1 = buffer.readu8(sY, src) + buffer.readu8(sY, src + width)
					src += 1

					y = bit32.bor(y, bit32.band(bit32.lshift(y1 + y2 + 2, 6), 0xff00))

					y2 = buffer.readu8(sY, src) + buffer.readu8(sY, src + width)
					src += 1

					y = bit32.bor(y, bit32.band(bit32.lshift(y1 + y2 + 2, 14), 0xff0000))

					y1 = buffer.readu8(sY, src) + buffer.readu8(sY, src + width)
					src += 1

					y = bit32.bor(y, bit32.band(bit32.lshift(y1 + y2 + 2, 22), 0xff000000))

					buffer.writeu32(dY, dest, y)
					dest += 4
				end

				dest += scan
				src += scan - 1
			end
		else
			while dest < last do
				y1 = buffer.readu8(sY, src)
				src += 1

				for x = 0, 3 do
					y2 = buffer.readu8(sY, src)
					src += 1

					y = bit32.band(bit32.rshift(y1 + y2 + 1, 1), 0xff)

					y1 = buffer.readu8(sY, src)
					src += 1

					y = bit32.bor(y, bit32.band(bit32.lshift(y1 + y2 + 1, 7), 0xff00))

					y2 = buffer.readu8(sY, src)
					src += 1

					y = bit32.bor(y, bit32.band(bit32.lshift(y1 + y2 + 1, 15), 0xff0000))

					y1 = buffer.readu8(sY, src)
					src += 1

					y = bit32.bor(y, bit32.band(bit32.lshift(y1 + y2 + 1, 23), 0xff000000))

					buffer.writeu32(dY, dest, y)
					dest += 4
				end

				dest += scan
				src += scan - 1
			end
		end
	else
		if oddV then
			while dest < last do
				for x = 0, 3 do
					y = bit32.band(bit32.rshift(buffer.readu8(sY, src) + buffer.readu8(sY, src + width) + 1, 1), 0xff)
					src += 1

					y = bit32.bor(
						y,
						bit32.band(bit32.lshift(buffer.readu8(sY, src) + buffer.readu8(sY, src + width) + 1, 7), 0xff00)
					)
					src += 1

					y = bit32.bor(
						y,
						bit32.band(
							bit32.lshift(buffer.readu8(sY, src) + buffer.readu8(sY, src + width) + 1, 15),
							0xff0000
						)
					)
					src += 1

					y = bit32.bor(
						y,
						bit32.band(
							bit32.lshift(buffer.readu8(sY, src) + buffer.readu8(sY, src + width) + 1, 23),
							0xff000000
						)
					)
					src += 1

					buffer.writeu32(dY, dest, y)
					dest += 4
				end

				dest += scan
				src += scan
			end
		else
			while dest < last do
				for x = 0, 3 do
					y = buffer.readu8(sY, src)
					src += 1

					y = bit32.bor(y, bit32.lshift(buffer.readu8(sY, src), 8))
					src += 1

					y = bit32.bor(y, bit32.lshift(buffer.readu8(sY, src), 16))
					src += 1

					y = bit32.bor(y, bit32.lshift(buffer.readu8(sY, src), 24))
					src += 1

					buffer.writeu32(dY, dest, y)
					dest += 4
				end

				dest += scan
				src += scan
			end
		end
	end

	width = self.halfWidth
	scan = width - 8

	local halfMotionH = (motionH < 0 and motionH % 2 ~= 0) and (motionH + 1) // 2 or motionH // 2
	local halfMotionV = (motionV < 0 and motionV % 2 ~= 0) and (motionV + 1) // 2 or motionV // 2

	H = halfMotionH // 2
	V = halfMotionV // 2
	oddH = (halfMotionH % 2 ~= 0)
	oddV = (halfMotionV % 2 ~= 0)

	src = (bit32.lshift(self.mbRow, 3) + V) * width + bit32.lshift(self.mbCol, 3) + H
	dest = bit32.lshift(self.mbRow * width + self.mbCol, 3)
	last = dest + bit32.lshift(width, 3)

	--stylua: ignore
	local cr1, cr2, cr,
		  cb1, cb2, cb

	if oddH then
		if oddV then
			while dest < last do
				cr1 = buffer.readu8(sCr, src) + buffer.readu8(sCr, src + width)
				cb1 = buffer.readu8(sCb, src) + buffer.readu8(sCb, src + width)
				src += 1

				for x = 0, 1 do
					cr2 = buffer.readu8(sCr, src) + buffer.readu8(sCr, src + width)
					cb2 = buffer.readu8(sCb, src) + buffer.readu8(sCb, src + width)
					src += 1

					cr = bit32.band(bit32.rshift(cr1 + cr2 + 2, 2), 0xff)
					cb = bit32.band(bit32.rshift(cb1 + cb2 + 2, 2), 0xff)

					cr1 = buffer.readu8(sCr, src) + buffer.readu8(sCr, src + width)
					cb1 = buffer.readu8(sCb, src) + buffer.readu8(sCb, src + width)
					src += 1

					cr = bit32.bor(cr, bit32.band(bit32.lshift(cr1 + cr2 + 2, 6), 0xff00))
					cb = bit32.bor(cb, bit32.band(bit32.lshift(cb1 + cb2 + 2, 6), 0xff00))

					cr2 = buffer.readu8(sCr, src) + buffer.readu8(sCr, src + width)
					cb2 = buffer.readu8(sCb, src) + buffer.readu8(sCb, src + width)
					src += 1

					cr = bit32.bor(cr, bit32.band(bit32.lshift(cr1 + cr2 + 2, 14), 0xff0000))
					cb = bit32.bor(cb, bit32.band(bit32.lshift(cb1 + cb2 + 2, 14), 0xff0000))

					cr1 = buffer.readu8(sCr, src) + buffer.readu8(sCr, src + width)
					cb1 = buffer.readu8(sCb, src) + buffer.readu8(sCb, src + width)
					src += 1

					cr = bit32.bor(cr, bit32.band(bit32.lshift(cr1 + cr2 + 2, 22), 0xff000000))
					cb = bit32.bor(cb, bit32.band(bit32.lshift(cb1 + cb2 + 2, 22), 0xff000000))

					buffer.writeu32(dCr, dest, cr)
					buffer.writeu32(dCb, dest, cb)
					dest += 4
				end

				dest += scan
				src += scan - 1
			end
		else
			while dest < last do
				cr1 = buffer.readu8(sCr, src)
				cb1 = buffer.readu8(sCb, src)
				src += 1

				for x = 0, 1 do
					cr2 = buffer.readu8(sCr, src)
					cb2 = buffer.readu8(sCb, src)
					src += 1

					cr = bit32.band(bit32.rshift(cr1 + cr2 + 1, 1), 0xff)
					cb = bit32.band(bit32.rshift(cb1 + cb2 + 1, 1), 0xff)

					cr1 = buffer.readu8(sCr, src)
					cb1 = buffer.readu8(sCb, src)
					src += 1

					cr = bit32.bor(cr, bit32.band(bit32.lshift(cr1 + cr2 + 1, 7), 0xff00))
					cb = bit32.bor(cb, bit32.band(bit32.lshift(cb1 + cb2 + 1, 7), 0xff00))

					cr2 = buffer.readu8(sCr, src)
					cb2 = buffer.readu8(sCb, src)
					src += 1

					cr = bit32.bor(cr, bit32.band(bit32.lshift(cr1 + cr2 + 1, 15), 0xff0000))
					cb = bit32.bor(cb, bit32.band(bit32.lshift(cb1 + cb2 + 1, 15), 0xff0000))

					cr1 = buffer.readu8(sCr, src)
					cb1 = buffer.readu8(sCb, src)
					src += 1

					cr = bit32.bor(cr, bit32.band(bit32.lshift(cr1 + cr2 + 1, 23), 0xff000000))
					cb = bit32.bor(cb, bit32.band(bit32.lshift(cb1 + cb2 + 1, 23), 0xff000000))

					buffer.writeu32(dCr, dest, cr)
					buffer.writeu32(dCb, dest, cb)
					dest += 4
				end

				dest += scan
				src += scan - 1
			end
		end
	else
		if oddV then
			while dest < last do
				for x = 0, 1 do
					cr =
						bit32.band(bit32.rshift(buffer.readu8(sCr, src) + buffer.readu8(sCr, src + width) + 1, 1), 0xff)
					cb =
						bit32.band(bit32.rshift(buffer.readu8(sCb, src) + buffer.readu8(sCb, src + width) + 1, 1), 0xff)
					src += 1

					cr = bit32.bor(
						cr,
						bit32.band(
							bit32.lshift(buffer.readu8(sCr, src) + buffer.readu8(sCr, src + width) + 1, 7),
							0xff00
						)
					)
					cb = bit32.bor(
						cb,
						bit32.band(
							bit32.lshift(buffer.readu8(sCb, src) + buffer.readu8(sCb, src + width) + 1, 7),
							0xff00
						)
					)
					src += 1

					cr = bit32.bor(
						cr,
						bit32.band(
							bit32.lshift(buffer.readu8(sCr, src) + buffer.readu8(sCr, src + width) + 1, 15),
							0xff0000
						)
					)
					cb = bit32.bor(
						cb,
						bit32.band(
							bit32.lshift(buffer.readu8(sCb, src) + buffer.readu8(sCb, src + width) + 1, 15),
							0xff0000
						)
					)
					src += 1

					cr = bit32.bor(
						cr,
						bit32.band(
							bit32.lshift(buffer.readu8(sCr, src) + buffer.readu8(sCr, src + width) + 1, 23),
							0xff000000
						)
					)
					cb = bit32.bor(
						cb,
						bit32.band(
							bit32.lshift(buffer.readu8(sCb, src) + buffer.readu8(sCb, src + width) + 1, 23),
							0xff000000
						)
					)
					src += 1

					buffer.writeu32(dCr, dest, cr)
					buffer.writeu32(dCb, dest, cb)
					dest += 4
				end

				dest += scan
				src += scan
			end
		else
			while dest < last do
				for x = 0, 1 do
					cr = buffer.readu8(sCr, src)
					cb = buffer.readu8(sCb, src)
					src += 1

					cr = bit32.bor(cr, bit32.lshift(buffer.readu8(sCr, src), 8))
					cb = bit32.bor(cb, bit32.lshift(buffer.readu8(sCb, src), 8))
					src += 1

					cr = bit32.bor(cr, bit32.lshift(buffer.readu8(sCr, src), 16))
					cb = bit32.bor(cb, bit32.lshift(buffer.readu8(sCb, src), 16))
					src += 1

					cr = bit32.bor(cr, bit32.lshift(buffer.readu8(sCr, src), 24))
					cb = bit32.bor(cb, bit32.lshift(buffer.readu8(sCb, src), 24))
					src += 1

					buffer.writeu32(dCr, dest, cr)
					buffer.writeu32(dCb, dest, cb)
					dest += 4
				end

				dest += scan
				src += scan
			end
		end
	end
end

function mpeg.decodeMotionVectors(self: mpeg)
	local code = 0
	local d = 0
	local r = 0

	if self.macroblockMotFw then
		code = mpeg.readHuffman(self, constants.MOTION)

		if (code ~= 0) and (self.forwardF ~= 1) then
			r = bitReader.read(self.bits, self.forwardRSize)
			d = bit32.lshift(math.abs(code) - 1, self.forwardRSize) + r + 1

			if code < 0 then
				d = -d
			end
		else
			d = code
		end

		self.motionFwHPrev += d
		if self.motionFwHPrev > (bit32.lshift(self.forwardF, 4) - 1) then
			self.motionFwHPrev -= bit32.lshift(self.forwardF, 5)
		elseif self.motionFwHPrev < -(bit32.lshift(self.forwardF, 4)) then
			self.motionFwHPrev += bit32.lshift(self.forwardF, 5)
		end

		self.motionFwH = self.motionFwHPrev
		if self.fullPelForward then
			self.motionFwH = self.motionFwH * 2
		end

		code = mpeg.readHuffman(self, constants.MOTION)

		if (code ~= 0) and (self.forwardF ~= 1) then
			r = bitReader.read(self.bits, self.forwardRSize)
			d = bit32.lshift(math.abs(code) - 1, self.forwardRSize) + r + 1

			if code < 0 then
				d = -d
			end
		else
			d = code
		end

		self.motionFwVPrev += d
		if self.motionFwVPrev > (bit32.lshift(self.forwardF, 4) - 1) then
			self.motionFwVPrev -= bit32.lshift(self.forwardF, 5)
		elseif self.motionFwVPrev < -(bit32.lshift(self.forwardF, 4)) then
			self.motionFwVPrev += bit32.lshift(self.forwardF, 5)
		end

		self.motionFwV = self.motionFwVPrev
		if self.fullPelForward then
			self.motionFwV = self.motionFwV * 2
		end
	elseif self.pictureType == constants.PICTURE_TYPE.PREDICTIVE then
		self.motionFwH = 0
		self.motionFwHPrev = 0

		self.motionFwV = 0
		self.motionFwVPrev = 0
	end
end

function mpeg.copyValueToDestination(self: mpeg, value: number, dest: buffer, index: number, scan: number)
	local n = 0

	while n < 64 do
		buffer.writeu8(dest, index + 0, value)
		buffer.writeu8(dest, index + 1, value)
		buffer.writeu8(dest, index + 2, value)
		buffer.writeu8(dest, index + 3, value)
		buffer.writeu8(dest, index + 4, value)
		buffer.writeu8(dest, index + 5, value)
		buffer.writeu8(dest, index + 6, value)
		buffer.writeu8(dest, index + 7, value)

		n += 8
		index += scan + 8
	end
end

function mpeg.IDCT(self: mpeg, block: { number })
	--stylua: ignore
	local b1, b3, b4, b6, b7, tmp1, tmp2, m0,
		  x0, x1, x2, x3, x4, y3, y4, y5, y6, y7

	for i = 0, 7 do
		b1 = block[4 * 8 + i + 1]
		b3 = block[2 * 8 + i + 1] + block[6 * 8 + i + 1]
		b4 = block[5 * 8 + i + 1] - block[3 * 8 + i + 1]

		tmp1 = block[1 * 8 + i + 1] + block[7 * 8 + i + 1]
		tmp2 = block[3 * 8 + i + 1] + block[5 * 8 + i + 1]

		b6 = block[1 * 8 + i + 1] - block[7 * 8 + i + 1]
		b7 = tmp1 + tmp2

		m0 = block[0 * 8 + i + 1]

		x4 = (b6 * 473 - b4 * 196 + 128) // 256 - b7
		x0 = x4 - ((tmp1 - tmp2) * 362 + 128) // 256
		x1 = m0 - b1
		x2 = ((block[2 * 8 + i + 1] - block[6 * 8 + i + 1]) * 362 + 128) // 256 - b3
		x3 = m0 + b1

		y3 = x1 + x2
		y4 = x3 + b3
		y5 = x1 - x2
		y6 = x3 - b3
		y7 = -x0 - (b4 * 473 + b6 * 196 + 128) // 256

		block[0 * 8 + i + 1] = b7 + y4
		block[1 * 8 + i + 1] = x4 + y3
		block[2 * 8 + i + 1] = y5 - x0
		block[3 * 8 + i + 1] = y6 - y7
		block[4 * 8 + i + 1] = y6 + y7
		block[5 * 8 + i + 1] = x0 + y5
		block[6 * 8 + i + 1] = y3 - x4
		block[7 * 8 + i + 1] = y4 - b7
	end

	for i = 0, 56, 8 do
		b1 = block[4 + i + 1]
		b3 = block[2 + i + 1] + block[6 + i + 1]
		b4 = block[5 + i + 1] - block[3 + i + 1]

		tmp1 = block[1 + i + 1] + block[7 + i + 1]
		tmp2 = block[3 + i + 1] + block[5 + i + 1]

		b6 = block[1 + i + 1] - block[7 + i + 1]
		b7 = tmp1 + tmp2

		m0 = block[0 + i + 1]

		x4 = ((b6 * 473) - (b4 * 196) + 128) // 256 - b7
		x0 = x4 - ((tmp1 - tmp2) * 362 + 128) // 256
		x1 = m0 - b1
		x2 = ((block[2 + i + 1] - block[6 + i + 1]) * 362 + 128) // 256 - b3
		x3 = m0 + b1

		y3 = x1 + x2
		y4 = x3 + b3
		y5 = x1 - x2
		y6 = x3 - b3
		y7 = -x0 - ((b4 * 473) + (b6 * 196) + 128) // 256

		block[0 + i + 1] = (b7 + y4 + 128) // 256
		block[1 + i + 1] = (x4 + y3 + 128) // 256
		block[2 + i + 1] = (y5 - x0 + 128) // 256
		block[3 + i + 1] = (y6 - y7 + 128) // 256
		block[4 + i + 1] = (y6 + y7 + 128) // 256
		block[5 + i + 1] = (x0 + y5 + 128) // 256
		block[6 + i + 1] = (y3 - x4 + 128) // 256
		block[7 + i + 1] = (y4 - b7 + 128) // 256
	end
end

function mpeg.copyBlockToDestination(self: mpeg, block: { number }, dest: buffer, index: number, scan: number)
	local n = 0

	while n < 64 do
		buffer.writeu8(dest, index + 0, block[n + 1])
		buffer.writeu8(dest, index + 1, block[n + 2])
		buffer.writeu8(dest, index + 2, block[n + 3])
		buffer.writeu8(dest, index + 3, block[n + 4])
		buffer.writeu8(dest, index + 4, block[n + 5])
		buffer.writeu8(dest, index + 5, block[n + 6])
		buffer.writeu8(dest, index + 6, block[n + 7])
		buffer.writeu8(dest, index + 7, block[n + 8])

		n += 8
		index += scan + 8
	end
end

function mpeg.addValueToDestination(self: mpeg, value: number, dest: buffer, index: number, scan: number)
	local n = 0

	while n < 64 do
		buffer.writeu8(dest, index + 0, math.clamp(buffer.readu8(dest, index + 0) + value, 0, 255))
		buffer.writeu8(dest, index + 1, math.clamp(buffer.readu8(dest, index + 1) + value, 0, 255))
		buffer.writeu8(dest, index + 2, math.clamp(buffer.readu8(dest, index + 2) + value, 0, 255))
		buffer.writeu8(dest, index + 3, math.clamp(buffer.readu8(dest, index + 3) + value, 0, 255))
		buffer.writeu8(dest, index + 4, math.clamp(buffer.readu8(dest, index + 4) + value, 0, 255))
		buffer.writeu8(dest, index + 5, math.clamp(buffer.readu8(dest, index + 5) + value, 0, 255))
		buffer.writeu8(dest, index + 6, math.clamp(buffer.readu8(dest, index + 6) + value, 0, 255))
		buffer.writeu8(dest, index + 7, math.clamp(buffer.readu8(dest, index + 7) + value, 0, 255))

		n += 8
		index += scan + 8
	end
end

function mpeg.addBlockToDestination(self: mpeg, block: { number }, dest: buffer, index: number, scan: number)
	local n = 0

	while n < 64 do
		buffer.writeu8(dest, index + 0, math.clamp(buffer.readu8(dest, index + 0) + block[n + 1], 0, 255))
		buffer.writeu8(dest, index + 1, math.clamp(buffer.readu8(dest, index + 1) + block[n + 2], 0, 255))
		buffer.writeu8(dest, index + 2, math.clamp(buffer.readu8(dest, index + 2) + block[n + 3], 0, 255))
		buffer.writeu8(dest, index + 3, math.clamp(buffer.readu8(dest, index + 3) + block[n + 4], 0, 255))
		buffer.writeu8(dest, index + 4, math.clamp(buffer.readu8(dest, index + 4) + block[n + 5], 0, 255))
		buffer.writeu8(dest, index + 5, math.clamp(buffer.readu8(dest, index + 5) + block[n + 6], 0, 255))
		buffer.writeu8(dest, index + 6, math.clamp(buffer.readu8(dest, index + 6) + block[n + 7], 0, 255))
		buffer.writeu8(dest, index + 7, math.clamp(buffer.readu8(dest, index + 7) + block[n + 8], 0, 255))

		n += 8
		index += scan + 8
	end
end

function mpeg.decodeBlock(self: mpeg, block: number)
	local n = 0
	local quantMatrix

	if self.macroblockIntra then
		--stylua: ignore
		local predictor,
			  dctSize

		if block < 4 then
			predictor = self.dcPredictorY
			dctSize = mpeg.readHuffman(self, constants.DCT_DC_SIZE_LUMINANCE)
		else
			predictor = (block == 4) and self.dcPredictorCr or self.dcPredictorCb
			dctSize = mpeg.readHuffman(self, constants.DCT_DC_SIZE_CHROMINANCE)
		end

		if dctSize > 0 then
			local differential = bitReader.read(self.bits, dctSize)

			if bit32.band(differential, bit32.lshift(1, (dctSize - 1))) ~= 0 then
				self.blockData[1] = predictor + differential
			else
				self.blockData[1] = predictor + (differential + 1) - bit32.lshift(1, dctSize)
			end
		else
			self.blockData[1] = predictor
		end

		if block < 4 then
			self.dcPredictorY = self.blockData[1]
		elseif block == 4 then
			self.dcPredictorCr = self.blockData[1]
		else
			self.dcPredictorCb = self.blockData[1]
		end

		self.blockData[1] = self.blockData[1] * 256

		quantMatrix = self.intraQuantMatrix
		n = 1
	else
		quantMatrix = self.nonIntraQuantMatrix
	end

	local level = 0
	while true do
		local run = 0
		local coeff = mpeg.readHuffman(self, constants.DCT_COEFF)

		if (coeff == 0x0001) and (n > 0) and (bitReader.read(self.bits, 1) == 0) then
			break
		end

		if coeff == 0xffff then
			run = bitReader.read(self.bits, 6)
			level = bitReader.read(self.bits, 8)

			if level == 0 then
				level = bitReader.read(self.bits, 8)
			elseif level == 128 then
				level = bitReader.read(self.bits, 8) - 256
			elseif level > 128 then
				level = level - 256
			end
		else
			run = bit32.rshift(coeff, 8)
			level = bit32.band(coeff, 0xff)

			if bitReader.read(self.bits, 1) == 1 then
				level = -level
			end
		end

		n += run
		local dezigZagged = constants.ZIG_ZAG[n + 1]
		dezigZagged += 1
		n += 1

		level = level * 2
		if self.macroblockIntra then
			level += ((level < 0) and -1 or 1)
		end

		level = (level * self.quantizerScale * quantMatrix[dezigZagged]) // 16
		if bit32.band(level, 1) == 0 then
			level -= ((level > 0) and 1 or -1)
		end

		if level > 2047 then
			level = 2047
		elseif level < -2048 then
			level = -2048
		end

		self.blockData[dezigZagged] = level * constants.PREMULTIPLIER_MATRIX[dezigZagged]
	end

	--stylua: ignore
	local destArray,
		  destIndex,
		  scan

	if block < 4 then
		destArray = self.currentY
		scan = self.codedWidth - 8
		destIndex = bit32.lshift(self.mbRow * self.codedWidth + self.mbCol, 4)

		if bit32.band(block, 1) ~= 0 then
			destIndex += 8
		end

		if bit32.band(block, 2) ~= 0 then
			destIndex += bit32.lshift(self.codedWidth, 3)
		end
	else
		destArray = (block == 4) and self.currentCb or self.currentCr
		scan = bit32.rshift(self.codedWidth, 1) - 8
		destIndex = bit32.lshift(self.mbRow * self.codedWidth, 2) + bit32.lshift(self.mbCol, 3)
	end

	if self.macroblockIntra then
		if n == 1 then
			mpeg.copyValueToDestination(self, (self.blockData[1] + 128) // 256, destArray, destIndex, scan)
			self.blockData[1] = 0
		else
			mpeg.IDCT(self, self.blockData)
			mpeg.copyBlockToDestination(self, self.blockData, destArray, destIndex, scan)

			for i = 1, 64 do
				self.blockData[i] = 0
			end
		end
	else
		if n == 1 then
			mpeg.addValueToDestination(self, (self.blockData[1] + 128) // 256, destArray, destIndex, scan)
			self.blockData[1] = 0
		else
			mpeg.IDCT(self, self.blockData)
			mpeg.addBlockToDestination(self, self.blockData, destArray, destIndex, scan)

			for i = 1, 64 do
				self.blockData[i] = 0
			end
		end
	end

	n = 0
end

function mpeg.decodeMacroblock(self: mpeg)
	local increment = 0
	local t = mpeg.readHuffman(self, constants.MACROBLOCK_ADDRESS_INCREMENT)

	while t == 34 do
		t = mpeg.readHuffman(self, constants.MACROBLOCK_ADDRESS_INCREMENT)
	end

	while t == 35 do
		increment += 33
		t = mpeg.readHuffman(self, constants.MACROBLOCK_ADDRESS_INCREMENT)
	end

	increment += t

	if self.sliceBegin then
		self.sliceBegin = false
		self.macroblockAddress += increment
	else
		if self.macroblockAddress + increment >= self.mbSize then
			return
		end

		if increment > 1 then
			self.dcPredictorY = 128
			self.dcPredictorCr = 128
			self.dcPredictorCb = 128

			if self.pictureType == constants.PICTURE_TYPE.PREDICTIVE then
				self.motionFwH = 0
				self.motionFwHPrev = 0

				self.motionFwV = 0
				self.motionFwVPrev = 0
			end
		end

		while increment > 1 do
			self.macroblockAddress += 1
			self.mbRow = self.macroblockAddress // self.mbWidth
			self.mbCol = self.macroblockAddress % self.mbWidth

			--stylua: ignore
			mpeg.copyMacroblock(self,
				self.motionFwH, self.motionFwV,
				self.forwardY, self.forwardCr, self.forwardCb
			)

			increment -= 1
		end

		self.macroblockAddress += 1
	end

	self.mbRow = self.macroblockAddress // self.mbWidth
	self.mbCol = self.macroblockAddress % self.mbWidth

	local mbTable = constants.MACROBLOCK_TYPE[self.pictureType]
	self.macroblockType = mpeg.readHuffman(self, mbTable)

	self.macroblockIntra = (bit32.band(self.macroblockType, 0x01) == 1)
	self.macroblockMotFw = (bit32.band(self.macroblockType, 0x08) ~= 0)

	if bit32.band(self.macroblockType, 0x10) ~= 0 then
		self.quantizerScale = bitReader.read(self.bits, 5)
	end

	if self.macroblockIntra then
		self.motionFwH = 0
		self.motionFwHPrev = 0

		self.motionFwV = 0
		self.motionFwVPrev = 0
	else
		self.dcPredictorY = 128
		self.dcPredictorCr = 128
		self.dcPredictorCb = 128

		--stylua: ignore start
		mpeg.decodeMotionVectors(self)
		mpeg.copyMacroblock(self,
			self.motionFwH, self.motionFwV,
			self.forwardY, self.forwardCr, self.forwardCb
		)
		--stylua: ignore end
	end

	local cbp = (bit32.band(self.macroblockType, 0x02) ~= 0) and mpeg.readHuffman(self, constants.CODE_BLOCK_PATTERN)
		or (self.macroblockIntra and 0x3f or 0)

	local mask = 0x20
	for block = 0, 5 do
		if bit32.band(cbp, mask) ~= 0 then
			mpeg.decodeBlock(self, block)
		end

		mask = bit32.rshift(mask, 1)
	end
end

function mpeg.decodeSlice(self: mpeg, slice: number)
	self.sliceBegin = true
	self.macroblockAddress = (slice - 1) * self.mbWidth - 1

	self.motionFwH = 0
	self.motionFwHPrev = 0

	self.motionFwV = 0
	self.motionFwVPrev = 0

	self.dcPredictorY = 128
	self.dcPredictorCr = 128
	self.dcPredictorCb = 128

	self.quantizerScale = bitReader.read(self.bits, 5)

	while bitReader.read(self.bits, 1) == 1 do
		bitReader.read(self.bits, 8)
	end

	repeat
		mpeg.decodeMacroblock(self)
	until bitReader.nextBytesAreStartCode(self.bits)
end

function mpeg.decodePicture(self: mpeg)
	self.currentFrame += 1

	bitReader.skip(self.bits, 10)
	self.pictureType = bitReader.read(self.bits, 3)
	bitReader.skip(self.bits, 16)

	if self.pictureType <= 0 or self.pictureType >= constants.PICTURE_TYPE.B then
		return
	end

	if self.pictureType == constants.PICTURE_TYPE.PREDICTIVE then
		self.fullPelForward = (bitReader.read(self.bits, 1) == 1) -- a
		self.forwardFCode = bitReader.read(self.bits, 3)

		if self.forwardFCode == 0 then
			return
		end

		self.forwardRSize = self.forwardFCode - 1
		self.forwardF = bit32.lshift(1, self.forwardRSize)
	end

	local code = 0
	repeat
		code = bitReader.findNextStartCode(self.bits)
	until code ~= constants.START.EXTENSION and code ~= constants.START.USER_DATA


	while code >= constants.START.SLICE_FIRST and code <= constants.START.SLICE_LAST do
		mpeg.decodeSlice(self, bit32.band(code, 0x000000FF))
		code = bitReader.findNextStartCode(self.bits)
	end

	if code ~= -1 then
		bitReader.rewind(self.bits, 32)
	end

	if self.pictureType == constants.PICTURE_TYPE.INTRA or self.pictureType == constants.PICTURE_TYPE.PREDICTIVE then
		local tmpY = self.forwardY
		local tmpCr = self.forwardCr
		local tmpCb = self.forwardCb

		self.forwardY = self.currentY
		self.forwardCr = self.currentCr
		self.forwardCb = self.currentCb

		self.currentY = tmpY
		self.currentCr = tmpCr
		self.currentCb = tmpCb
	end
end

return mpeg
