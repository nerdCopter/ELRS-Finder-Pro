-- ELRS_Finder_Power.lua  (EdgeTX B/W 128x64, ELRS 3.x / 4.x)
--
-- RSSI-based lost-model finder with automatic TX power management.
-- On init:    discovers TX Power field via CRSF, saves current index. Does NOT force
--             low power immediately — ELRS_Finder.lua's own advice is "lower TX power
--             as you get close", not "start the search at minimum".
-- While running: auto-ratchets power down (never up) as signal strength crosses a
--             series of thresholds, so link margin is kept while the model could
--             still be far/blocked, and power drops only once you're closing in.
--             Scroll-wheel/rotary input (EVT_VIRTUAL_NEXT/PREV) always overrides —
--             once the pilot manually adjusts power, auto-ratchet stops touching it
--             for the rest of the session.
-- On exit:   restores the saved power index before returning to EdgeTX.
--
-- Install: /SCRIPTS/TOOLS/ELRS_Finder_Power.lua on the SD card.
-- Requires CRSF/ELRS TX module active.
--
-- Discovery/parsing engine mirrors elrs.lua (master, r18) architecture and naming:
-- loadQ stack of pending field IDs, single field in flight, fields_count/fieldChunk/
-- fieldData/fieldTimeout state, parseDeviceInfoMessage/parseParameterInfoMessage/
-- refreshNext. handsetId is fixed 0xEA (RADIO_TRANSMITTER) matching current master —
-- unlike elrsV3.lua (3.x-maintenance), master no longer switches to 0xEF for ELRS TX.
-- String reads avoid the `table` library (not present in this script sandbox); build
-- via `..` concatenation, matching how elrs.lua itself avoids table.*.

-- ─── Constants ───────────────────────────────────────────────────────────────

local VERSION = "0.1.0"  -- matches the GitHub release tag; bump on every release

local deviceId  = 0xEE   -- ELRS TX module CRSF address
local handsetId = 0xEA   -- RADIO_TRANSMITTER; matches elrs.lua master (r18)

local DEVICES_CMD     = 0x28   -- ping / device discovery
local DEVICE_INFO_CMD = 0x29   -- device info response
local FIELD_REQ_CMD    = 0x2C   -- parameter read request
local FIELD_INFO_CMD  = 0x2B   -- parameter info response
local FIELD_WRITE_CMD = 0x2D   -- parameter write

local FIELD_TIMEOUT_TICKS  = 50    -- 0.5s retry-if-no-response; matches elrs.lua's local-TX cadence
local RESTORE_HOLD_TICKS   = 80    -- 0.8s to let write propagate before exit
local DISCOVER_RETRY_TICKS = 100   -- 1s between discovery pings

local FIELD_TYPE_SELECT = 9   -- CRSF SELECT (TEXT_SELECTION) field type

-- ─── Power-management state machine ──────────────────────────────────────────
-- (elrs.lua has no equivalent — this layer is our own addition on top of its
-- field-discovery engine.)

local STATE_DISCOVER = 1
local STATE_SCAN     = 2
local STATE_FINDING  = 3
local STATE_RESTORE  = 4
local STATE_EXIT     = 5

local state

-- ─── Field-discovery engine state (naming mirrors elrs.lua) ─────────────────

local fields_count
local loadQ            -- stack of pending field IDs; requests loadQ[#loadQ]
local fieldChunk        -- count of chunks received for the field in flight
local fieldData         -- accumulator for the field in flight
local fieldTimeout      -- deadline tick for the next (re)request
local discoverTimeout    -- deadline tick for the next discovery ping

local powerFieldId    -- field ID of the "TX Power" / "Max Power" entry
local savedPower      -- original power selection index to restore on exit
local savedPowerLabel -- label text of the original power option (what RESTORE reverts to)
local powerOptions    -- 1-indexed array of "label+unit" strings, index N+1 = option N
local powerIndex      -- current live (possibly unconfirmed) power index while FINDING
local committedPowerIndex -- last index actually written to the module
local powerEditing        -- true while an edit is in progress (blinking, unconfirmed)
local autoStepsApplied -- count of auto-ratchet thresholds already crossed
local manualOverride   -- true once the pilot enters edit mode; disables auto-ratchet

local exitscript

local lastBeep
local signalAvg

-- ─── Utility helpers ─────────────────────────────────────────────────────────

local function clamp(value, minimum, maximum)
  return value < minimum and minimum or (value > maximum and maximum or value)
end

-- Return the string content and the offset of the byte after the null terminator.
-- Built via string concatenation (matches elrs.lua's fieldGetStrOrOpts) — the
-- `table` library is not present in this script's sandbox.
local function readString(data, offset)
  local str = ""
  while data[offset] and data[offset] ~= 0 do
    str = str .. string.char(data[offset])
    offset = offset + 1
  end
  return str, offset + 1
end

-- ─── CRSF helpers ────────────────────────────────────────────────────────────

local function pingDevices()
  crossfireTelemetryPush(DEVICES_CMD, { 0x00, 0xEA })
end

local function requestFieldById(id, chunk)
  crossfireTelemetryPush(FIELD_REQ_CMD, { deviceId, handsetId, id, chunk })
end

local function writeFieldValue(id, value)
  crossfireTelemetryPush(FIELD_WRITE_CMD, { deviceId, handsetId, id, value })
end

-- ─── CRSF packet parsers (structure mirrors elrs.lua) ───────────────────────

local function parseDeviceInfoMessage(data)
  if data[2] ~= deviceId then return end
  local _, offset = readString(data, 3)
  fields_count = data[offset + 12] or fields_count
end

-- Examine a complete field payload starting at `offset` (the parent byte).
-- Sets powerFieldId / savedPower when a power-related SELECT field is found.
-- Split the semicolon-delimited option-values string into a 1-indexed array of
-- labels (index N's label is opts[N+1]), returning the offset of the value byte
-- that follows. Plain table + `..` concatenation — no `table` library calls.
local function readOptions(data, offset)
  local opts, opt, n = {}, "", 0
  while true do
    local b = data[offset]
    offset = offset + 1
    if b == nil or b == 0 or b == 59 then -- ';'
      n = n + 1
      opts[n] = opt
      opt = ""
      if b == nil or b == 0 then break end
    else
      opt = opt .. string.char(b)
    end
  end
  return opts, offset
end

local function examineField(fieldId, data, offset)
  if not data[offset + 1] then return end
  local fieldType = bit32.band(data[offset + 1], 0x7f)
  local name, nameEnd = readString(data, offset + 2)

  if fieldType ~= FIELD_TYPE_SELECT then return end
  if not string.find(string.lower(name), "power") then return end

  local opts, valueOffset = readOptions(data, nameEnd)
  savedPower   = data[valueOffset]
  powerFieldId = fieldId

  -- Unit isn't part of the options list; it's a separate string after
  -- value/min/max/default (1 byte each) — matches elrs.lua's fieldTextSelLoad.
  local unit = readString(data, valueOffset + 4)
  powerOptions = {}
  for i = 1, #opts do
    powerOptions[i] = (opts[i] or "?") .. unit
  end
  savedPowerLabel = powerOptions[savedPower + 1]
end

-- Mirrors elrs.lua's parseParameterInfoMessage: accumulate chunks for the one
-- field currently in flight (loadQ[#loadQ]), examine once chunksRemain == 0.
local function parseParameterInfoMessage(data)
  local fieldId = loadQ[#loadQ]
  if data[2] ~= deviceId or data[3] ~= fieldId then
    fieldData  = nil
    fieldChunk = 0
    return
  end

  local chunksRemain = data[4] or 0
  local offset
  if chunksRemain > 0 or fieldChunk > 0 then
    fieldData = fieldData or {}
    for i = 5, #data do fieldData[#fieldData + 1] = data[i] end
    offset = 1
  else
    fieldData = data
    offset = 5
  end

  if chunksRemain > 0 then
    fieldChunk   = fieldChunk + 1
    fieldTimeout = 0   -- request the next chunk immediately, don't wait out the timeout
    return
  end

  loadQ[#loadQ] = nil
  fieldChunk    = 0
  fieldTimeout  = 0   -- request the next field immediately, don't wait out the timeout

  examineField(fieldId, fieldData, offset)
  fieldData = nil
end

-- Build the descending stack of field IDs to request (matches elrs.lua's reloadAllField).
local function reloadAllField()
  fieldChunk = 0
  fieldData  = nil
  loadQ      = {}
  for fieldId = fields_count, 1, -1 do
    loadQ[#loadQ + 1] = fieldId
  end
end

-- Drain pending CRSF packets and (re)request the field currently in flight.
-- Mirrors elrs.lua's refreshNext, narrowed to device-info + parameter-info only.
local function refreshNext()
  local command, data
  repeat
    command, data = crossfireTelemetryPop()
    if command == DEVICE_INFO_CMD then
      parseDeviceInfoMessage(data)
    elseif command == FIELD_INFO_CMD then
      parseParameterInfoMessage(data)
    end
  until command == nil

  local now = getTime()
  if not fields_count or fields_count == 0 then
    if now >= discoverTimeout then
      pingDevices()
      discoverTimeout = now + DISCOVER_RETRY_TICKS
    end
    return
  end

  if #loadQ > 0 and now >= fieldTimeout then
    requestFieldById(loadQ[#loadQ], fieldChunk)
    fieldTimeout = now + FIELD_TIMEOUT_TICKS
  end
end

-- ─── Signal reading ──────────────────────────────────────────────────────────

local function readSignalStrength()
  local rssi = getValue("1RSS")
  if rssi and rssi ~= 0 then return rssi, "dBm" end
  local snr = getValue("RSNR")
  if snr and snr ~= 0 then return snr * 2 - 120, "SNR" end
  local rql = getValue("RQly")
  if rql and rql ~= 0 then return rql - 120, "LQ%" end
  return -120, "NA"
end

-- ─── Finder page (beep + UI) ─────────────────────────────────────────────────

-- DBLSIZE dBm value + continuous S-meter below: a fixed-width outline track (always
-- visible 0-100% reference) with a proportional fill inside — finer resolution and
-- fewer draw calls (2, fixed) than the earlier N-segment version (N calls).
local BAR_W = 100  -- track width px
local BAR_H = 10   -- track height px
local BAR_X = math.floor((128 - BAR_W) / 2)
local BAR_Y = 26

-- Signal-strength percentages at which to ratchet power down one step. Ascending,
-- crossed in order, never reversed — a momentary dropout doesn't push power back up.
local AUTO_STEP_THRESHOLDS = { 30, 50, 70, 90 }

local cachedLineH -- measured once via lcd.sizeText, see the warning-row fit check below

local function runFinderPage(event)
  local now = getTime()
  local raw, source = readSignalStrength()

  signalAvg = 0.8 * signalAvg + 0.2 * raw

  local strength  = clamp((signalAvg + 110) * (100 / 70), 0, 100)
  local period    = clamp(120 - strength, 10, 120)   -- 1.2s far → 0.1s close
  if now - lastBeep >= period then
    playTone(clamp(600 + strength * 6, 600, 1200), 30, 0, 0)
    lastBeep = now
  end

  -- Manual power edit: mirrors elrs.lua's own edit-mode convention (ENTER starts/stops
  -- editing; NEXT/PREV only change the in-memory value while editing; EXIT while
  -- editing cancels instead of exiting the tool). Nothing is written until confirmed.
  local exitConsumed = false
  if powerFieldId and powerOptions then
    if not powerEditing then
      if event == EVT_VIRTUAL_ENTER then
        powerEditing   = true
        manualOverride = true   -- pilot has taken control; auto-ratchet stops for good
      elseif not manualOverride then
        local wantSteps = 0
        for i, threshold in ipairs(AUTO_STEP_THRESHOLDS) do
          if strength >= threshold then wantSteps = i end
        end
        if wantSteps > autoStepsApplied then
          local newIndex = clamp(powerIndex - (wantSteps - autoStepsApplied), 0, #powerOptions - 1)
          autoStepsApplied = wantSteps
          if newIndex ~= powerIndex then
            powerIndex = newIndex
            writeFieldValue(powerFieldId, powerIndex)
          end
        end
      end
    else -- powerEditing: blinking, nothing written yet
      if event == EVT_VIRTUAL_NEXT or event == EVT_VIRTUAL_PREV then
        local step = (event == EVT_VIRTUAL_NEXT) and 1 or -1
        powerIndex = clamp(powerIndex + step, 0, #powerOptions - 1)
      elseif event == EVT_VIRTUAL_ENTER then
        powerEditing        = false
        committedPowerIndex = powerIndex
        writeFieldValue(powerFieldId, powerIndex)
      elseif event == EVT_VIRTUAL_EXIT then
        powerEditing = false
        powerIndex   = committedPowerIndex   -- cancel: discard the unconfirmed change
        exitConsumed = true                  -- this EXIT cancels edit, not the whole tool
      end
    end
  end

  local fillW     = math.floor(strength * BAR_W / 100)
  local pwrLabel  = (powerFieldId and powerOptions and powerOptions[powerIndex + 1]) or "?"

  lcd.clear()

  -- Title row: script name left, source tag right
  lcd.drawText(2, 1, "ELRS Finder", 0)
  lcd.drawText(LCD_W - 1, 1, source, RIGHT)

  -- Large dBm reading centered
  lcd.drawText(LCD_W / 2, 10, string.format("%d dBm", math.floor(signalAvg)), DBLSIZE + CENTER)

  -- Continuous S-meter: fixed outline track (0-100% reference) + proportional fill
  lcd.drawRectangle(BAR_X, BAR_Y, BAR_W, BAR_H)
  if fillW > 0 then
    lcd.drawFilledRectangle(BAR_X, BAR_Y, fillW, BAR_H)
  end

  -- Status row — only the value blinks (inverted) while an unconfirmed edit is in
  -- progress, not the whole line; "Power:" label stays plain. Centered as one unit
  -- (measured combined width), even though it's drawn as two separate calls.
  local pwrPrefix = "Power: "
  local pwrAttr   = powerEditing and (BLINK + INVERS) or 0
  local prefixW   = lcd.sizeText and lcd.sizeText(pwrPrefix) or (5 * string.len(pwrPrefix))
  local valueW    = lcd.sizeText and lcd.sizeText(pwrLabel) or (5 * string.len(pwrLabel))
  local pwrX      = math.floor((LCD_W - (prefixW + valueW)) / 2)
  lcd.drawText(pwrX, 38, pwrPrefix, 0)
  lcd.drawText(pwrX + prefixW, 38, pwrLabel, pwrAttr)
  lcd.drawText(2, 48, powerEditing and "[ENT]:set [RTN]:cancel" or "[RTN]:exit [ENT]:edit power", SMLSIZE)

  -- Only draw the power-off warning if it actually fits below the RTN row without
  -- clipping — measure the real line height (elrs.lua's own technique, line 862:
  -- `textWidth, textSize = lcd.sizeText("Qg")`), don't assume a fixed 8px.
  if not cachedLineH then
    if lcd.sizeText then
      local _, h = lcd.sizeText("Qg")
      cachedLineH = h
    else
      cachedLineH = 8
    end
  end
  local warnY = 48 + cachedLineH
  if warnY + cachedLineH <= LCD_H then
    lcd.drawText(2, warnY, "PwrOff/RTNhold=no restore", SMLSIZE)
  end

  if event == EVT_VIRTUAL_EXIT and not exitConsumed then
    state = STATE_RESTORE
  end
end

-- ─── Discovery / scan pages ──────────────────────────────────────────────────

local function drawHeader(line2)
  lcd.clear()
  lcd.drawText(2, 2, "ELRS Finder Pro", MIDSIZE)
  lcd.drawText(LCD_W - 1, 2, VERSION, SMLSIZE + RIGHT)
  lcd.drawText(2, 18, line2, 0)
end

-- ─── Main run function ───────────────────────────────────────────────────────

local crashMsg

-- Wrap the raw error text at LCD width so nothing gets clipped by the popup.
local function wrapText(msg, width)
  local lines, line = {}, ""
  for word in string.gmatch(msg, "%S+") do
    local candidate = (line == "" and word or (line .. " " .. word))
    if string.len(candidate) > width then
      lines[#lines + 1] = line
      line = word
    else
      line = candidate
    end
  end
  if line ~= "" then lines[#lines + 1] = line end
  return lines
end

local function runGuarded(event)
  refreshNext()

  if state == STATE_DISCOVER then
    drawHeader("Connecting...")
    if fields_count and fields_count > 0 then
      reloadAllField()
      state = STATE_SCAN
    end

  elseif state == STATE_SCAN then
    if powerFieldId or #loadQ == 0 then
      if powerFieldId then
        powerIndex          = savedPower
        committedPowerIndex = savedPower
      end
      state = STATE_FINDING
    else
      drawHeader(string.format("Scanning %d/%d...", fields_count - #loadQ + 1, fields_count))
    end

  elseif state == STATE_FINDING then
    runFinderPage(event)

  elseif state == STATE_RESTORE then
    drawHeader("Restoring " .. (savedPowerLabel or "?"))
    if powerFieldId and savedPower then
      writeFieldValue(powerFieldId, savedPower)
    end
    fieldTimeout = getTime() + RESTORE_HOLD_TICKS
    state        = STATE_EXIT

  elseif state == STATE_EXIT then
    drawHeader("Restoring " .. (savedPowerLabel or "?"))
    if getTime() >= fieldTimeout then
      exitscript = 1
    end
  end

  return exitscript
end

local function run(event)
  if crashMsg then
    lcd.clear()
    lcd.drawText(2, 1, "Lua error (frozen):", 0)
    local y = 11
    for _, line in ipairs(wrapText(crashMsg, 21)) do
      lcd.drawText(2, y, line, 0)
      y = y + 8
    end
    if event == EVT_VIRTUAL_EXIT then return 1 end
    return 0
  end

  local ok, result = pcall(runGuarded, event)
  if not ok then
    crashMsg = result
    return 0
  end
  return result
end

-- ─── Init ────────────────────────────────────────────────────────────────────

local function init()
  crashMsg        = nil
  state           = STATE_DISCOVER
  fields_count    = 0
  loadQ           = {}
  fieldChunk      = 0
  fieldData       = nil
  fieldTimeout    = 0
  discoverTimeout = 0
  powerFieldId     = nil
  savedPower       = nil
  savedPowerLabel  = nil
  powerOptions        = nil
  powerIndex          = nil
  committedPowerIndex = nil
  powerEditing        = false
  autoStepsApplied    = 0
  manualOverride      = false
  exitscript       = 0
  signalAvg       = -120
  lastBeep        = 0
  pingDevices()
end

return { init = init, run = run }
