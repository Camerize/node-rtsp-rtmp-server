# RTSP and RTMP/RTMPE/RTMPT/RTMPTE server implementation mainly for
# Raspberry Pi. Also serves HTTP contents as this server is meant to
# be run on port 80.

# TODO: clear old sessioncookies

net         = require 'net'
dgram       = require 'dgram'
fs          = require 'fs'
os          = require 'os'
crypto      = require 'crypto'
url         = require 'url'
path        = require 'path'
spawn       = require('child_process').spawn

codec_utils = require './codec_utils'
config      = require './config'
RTMPServer  = require './rtmp'
#HTTPHandler = require './http'
#rtsp        = require './rtsp'
#rtp         = require './rtp'
#sdp         = require './sdp'
h264        = require './h264'
aac         = require './aac'
#hybrid_udp  = require './hybrid_udp'
#bits        = require './bits'

# Clock rate for audio stream
audioClockRate = null


isVideoStarted = false
isAudioStarted = false

# Create RTMP server
rtmpServer = new RTMPServer config
rtmpServer.on 'stream_reset', (stream)->
  console.log 'stream_reset from rtmp source'
  resetStreams(stream)
rtmpServer.on 'video_start', (stream)->
  onReceiveVideoControlBuffer(stream)
rtmpServer.on 'video_data', (stream, pts, dts, nalUnits) ->
  onReceiveVideoPacket stream, nalUnits, pts, dts
rtmpServer.on 'audio_start', (stream)->
  onReceiveAudioControlBuffer(stream)
rtmpServer.on 'audio_data', (stream, pts, dts, adtsFrame) ->
  onReceiveAudioPacket stream, adtsFrame, pts, dts

# Reset audio/video streams
resetStreams = (stream) ->
  isVideoStarted = false
  isAudioStarted = false
  spropParameterSets = ''
  rtmpServer.resetStreams(stream)

rtmpServer.start ->
  # RTMP server is ready

updateConfig = (stream)->
  rtmpServer.updateConfig stream

# onReceiveBuffer = (buf) ->
#   packetType = buf[0]
#   switch packetType
#     when 0x00 then onReceiveVideoControlBuffer buf
#     when 0x01 then onReceiveAudioControlBuffer buf
#     when 0x02 then onReceiveVideoDataBuffer buf
#     when 0x03 then onReceiveAudioDataBuffer buf
#     when 0x04 then onReceiveVideoDataBufferWithDTS buf
#     when 0x05 then onReceiveAudioDataBufferWithDTS buf
#     else
#       console.log "unknown packet type: #{packetType}"
#       # ignore
#   return

onReceiveVideoControlBuffer = (stream, buf) ->
  console.log "video start #{stream.name}" 
  isVideoStarted = true
  timeForVideoRTPZero = Date.now()
  timeForAudioRTPZero = timeForVideoRTPZero
  spropParameterSets = ''
  rtmpServer.startVideo(stream)

onReceiveAudioControlBuffer = (stream, buf) ->
  console.log "audio start #{stream.name}"
  isAudioStarted = true
  timeForAudioRTPZero = Date.now()
  timeForVideoRTPZero = timeForAudioRTPZero
  rtmpServer.startAudio(stream)

# Generate random 32 bit unsigned integer.
# Return value is intended to be used as an SSRC identifier.
generateRandom32 = ->
  str = "#{new Date().getTime()}#{process.pid}#{os.hostname()}" + \
        "#{process.getuid()}#{process.getgid()}" + \
        (1 + Math.random() * 1000000000)

  md5sum = crypto.createHash 'md5'
  md5sum.update str
  md5sum.digest()[0..3].readUInt32BE(0)


# Takes one H.264 NAL unit as argument
#
# arguments:
#   nalUnit: Buffer
#   pts: timestamp in 90 kHz clock rate (PTS)
onReceiveVideoPacket = (stream, nalUnitGlob, pts, dts) ->
  nalUnits = h264.splitIntoNALUnits nalUnitGlob
  if nalUnits.length is 0
    return

  params = stream.params
  for nalUnit, i in nalUnits
    # detect configuration
    nalUnitType = h264.getNALUnitType nalUnit
    if config.dropH264AccessUnitDelimiter and
    (nalUnitType is h264.NAL_UNIT_TYPE_ACCESS_UNIT_DELIMITER)
      # ignore access unit delimiters
      continue
    if nalUnitType is h264.NAL_UNIT_TYPE_PPS
      rtmpServer.updatePPS stream, nalUnit
    else if nalUnitType is h264.NAL_UNIT_TYPE_SPS
      rtmpServer.updateSPS stream, nalUnit

  rtmpServer.sendVideoPacket stream, nalUnits, pts, dts

  return

updateAudioSampleRate = (stream,sampleRate) ->
  audioClockRate = sampleRate
  stream.params.audioSampleRate = sampleRate

updateAudioChannels = (stream, channels) ->
  stream.params.audioChannels = channels

onReceiveAudioPacket = (stream, adtsFrameGlob, pts, dts) ->
  adtsFrames = aac.splitIntoADTSFrames adtsFrameGlob
  if adtsFrames.length is 0
    return
  adtsInfo = aac.parseADTSFrame adtsFrames[0]

 
  if stream.params.audioSampleRate isnt adtsInfo.sampleRate
    stream.params.audioSampleRate = adtsInfo.sampleRate
    console.log "audio sample rate has been changed to #{adtsInfo.sampleRate}"
    updateAudioSampleRate stream, adtsInfo.sampleRate

  if stream.params.audioChannels  isnt adtsInfo.channels
    stream.params.audioChannels  = adtsInfo.channels
    console.log "audio channels has been changed to #{adtsInfo.channels}"
    updateAudioChannels stream, adtsInfo.channels

  if stream.params.audioObjectType isnt adtsInfo.audioObjectType
    stream.params.audioObjectType = adtsInfo.audioObjectType
    console.log "audio object type has been changed to #{stream.params.audioObjectType}"
    updateConfig(stream)


  ptsPerFrame = 90000 / (adtsInfo.sampleRate / 1024)

  # timestamp: RTP timestamp in audioClockRate
  # pts: PTS in 90 kHz clock
  if audioClockRate isnt 90000  # given pts is not in 90 kHz clock
    timestamp = pts * audioClockRate / 90000
  else
    timestamp = pts

  for adtsFrame, i in adtsFrames
    rawDataBlock = adtsFrame[7..]
    rtmpServer.sendAudioPacket stream, rawDataBlock,
      Math.round(pts + ptsPerFrame * i),
      Math.round(dts + ptsPerFrame * i)
  return

module.exports.setUp = -> rtmpServer
module.exports.allStreams = -> RTMPServer.streams


###
pad = (digits, n) ->
  n = n + ''
  while n.length < digits
    n = '0' + n
  n

getISO8601DateString = ->
  d = new Date
  str = "#{d.getUTCFullYear()}-#{pad 2, d.getUTCMonth()+1}-#{pad 2, d.getUTCDate()}T" + \
        "#{pad 2, d.getUTCHours()}:#{pad 2, d.getUTCMinutes()}:#{pad 2, d.getUTCSeconds()}." + \
        "#{pad 4, d.getUTCMilliseconds()}Z"
  str

consumePathname = (uri, callback) ->
  pathname = url.parse(uri).pathname[1..]

  # TODO: Implement authentication yourself
  authSuccess = true

  if authSuccess
    callback null
  else
    callback new Error 'Invalid access'

respondWithUnsupportedTransport = (callback, headers) ->
  res = 'RTSP/1.0 461 Unsupported Transport\n'
  if headers?
    for name, value of headers
      res += "#{name}: #{value}\n"
  res += '\n'
  callback null, res.replace /\n/g, '\r\n'

notFound = (protocol, opts, callback) ->
  res = """
  #{protocol}/1.0 404 Not Found
  Content-Length: 9
  Content-Type: text/plain

  """
  if opts?.keepalive
    res += "Connection: keep-alive\n"
  else
    res += "Connection: close\n"
  res += """

  Not Found
  """
  callback null, res.replace /\n/g, "\r\n"

respondWithNotFound = (protocol='RTSP', callback) ->
  res = """
  #{protocol}/1.0 404 Not Found
  Content-Length: 9
  Content-Type: text/plain

  Not Found
  """.replace /\n/g, "\r\n"
  callback null, res

# Check if the remote address of the given socket is private
isPrivateNetwork = (socket) ->
  if /^(10\.|192\.168\.|127\.0\.0\.)/.test socket.remoteAddress
    return true
  if (match = /^172.(\d+)\./.exec socket.remoteAddress)?
    num = parseInt match[1]
    if 16 <= num <= 31
      return true
  return false###