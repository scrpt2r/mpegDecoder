--!native
--!optimize 2

--// Lib Decleration
local types = {}

--// Global Types
export type bitReader = {
	index: number,
	byteLength: number,
	bytes: buffer,
}

export type packet = {
	type: number,
	pts: number,
	data: buffer,
	length: number,
}

export type demuxer = {
	buf: bitReader,
	startCode: number,

	hasPackHeader: boolean,
	hasSystemHeader: boolean,
	hasHeaders: boolean,

	sysClockRef: number,
	lastDecodedPts: number,

	numAudioStreams: number,
	numVideoStreams: number,

	currentPacket: packet,
	nextPacket: packet,
}

export type mpeg = {
	bits: bitReader,

	width: number,
	height: number,
	frameRate: number,
	currentFrame: number,

	hasSequenceHeader: boolean,

	customIntraQuantMatrix: { number },
	customNonIntraQuantMatrix: { number },

	intraQuantMatrix: { number },
	nonIntraQuantMatrix: { number },

	mbWidth: number,
	mbHeight: number,
	mbSize: number,

	codedWidth: number,
	codedHeight: number,
	codedSize: number,

	halfWidth: number,
	halfHeight: number,

	currentY: buffer,
	currentCr: buffer,
	currentCb: buffer,

	forwardY: buffer,
	forwardCr: buffer,
	forwardCb: buffer,

	pictureType: number,
	fullPelForward: boolean,

	forwardFCode: number,
	forwardRSize: number,
	forwardF: number,

	quantizerScale: number,
	sliceBegin: boolean,

	macroblockAddress: number,
	mbRow: number,
	mbCol: number,

	macroblockType: number,
	macroblockIntra: boolean,
	macroblockMotFw: boolean,

	motionFwH: number,
	motionFwV: number,
	motionFwHPrev: number,
	motionFwVPrev: number,

	dcPredictorY: number,
	dcPredictorCr: number,
	dcPredictorCb: number,

	blockData: { number },
}

return types
