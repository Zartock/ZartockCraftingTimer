-- Zartock Crafting Timer
--
-- While a queue of several crafts is running ("Create All", or a count above
-- one), shows how long it takes until the whole queue is done.
--
-- The game only tells addons about the craft that is being cast right now
-- (UnitCastingInfo) and how many more will follow it
-- (C_TradeSkillUI.GetRemainingRecasts). Every time a cast starts, the moment
-- the whole queue will be done is estimated as
--
--     end of the current cast + crafts still to come * (cast time + pause)
--
-- where the pause is the short break the server adds between crafts. The
-- display counts down to that moment on its own clock, so it keeps running
-- through the pauses.
--
-- The game does not tell addons how long that pause is, so it is measured. One
-- measurement is off by some network jitter, and in the estimate that error is
-- multiplied by the number of crafts left. So a queue does not use its own
-- measurements: it uses the long-run average of earlier queues, fixed for as
-- long as the queue runs, and its measurements only go into the average for
-- the next one. If the average is a little off, the timer runs a few percent
-- fast or slow, evenly, which cannot be seen.

local ADDON_NAME = ...

local DEFAULT_POSITION = { point = "CENTER", x = 0, y = -180 };

-- Between two crafts nothing is being cast for a moment. The timer stays up
-- for this long waiting for the next cast before it assumes the queue ended.
local GAP_GRACE = 1.5;

local UPDATE_INTERVAL = 0.1;

-- A pause between two casts is only believed when it is this short; anything
-- longer was lag or a restarted queue.
local MAX_GAP = 2;

-- The pause estimate is a running average over at most this many crafts.
local GAP_SAMPLES = 50;

-- /zct log keeps this many of the latest crafts in the saved variables.
local LOG_SIZE = 400;

-- When the estimate changes, the displayed timer does not jump to it. It
-- closes the difference gradually, a fraction of 1/SLEW_TIME of it per second,
-- so the usual small corrections are spread too thin to be seen. Large ones
-- are limited to running SLEW_MAX_RATE faster or slower than real time.
local SLEW_TIME = 5;
local SLEW_MAX_RATE = 0.5;

local db;

local state = {
    casting = false,    -- a craft is being cast right now
    multi = false,      -- this queue had more than one craft, so it is worth showing
    preview = false,    -- /zct: shown with sample numbers so it can be moved
    startTime = 0,      -- GetTime() at which the current cast started
    endTime = 0,        -- GetTime() at which the current cast ends
    lastEnd = nil,      -- endTime of the previous cast in this queue
    left = 0,           -- crafts left, including the current one
    gap = 0,            -- average pause between two crafts, over all queues
    queueGap = nil,     -- the pause this queue calculates with; nil until one is known
    gapSamples = 0,     -- how many measurements the average is made of
    target = 0,         -- GetTime() at which the queue is estimated to be done
    shown = nil,        -- the same, as displayed; follows target without jumping
    lastRefresh = 0,    -- GetTime() of the previous display update
    gapDeadline = 0,    -- GetTime() at which a pause between crafts is given up on
};

local function IsSecret(value)
    return issecretvalue ~= nil and issecretvalue(value);
end

local function FormatTime(seconds)
    seconds = math.ceil(seconds);
    if seconds >= 3600 then
        return string.format("%d:%02d:%02d", math.floor(seconds / 3600), math.floor(seconds % 3600 / 60), seconds % 60);
    end
    return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60);
end

----------------------------------------------------------------------------
-- Frame
----------------------------------------------------------------------------

local frame = CreateFrame("Frame", "ZartockCraftingTimerFrame", UIParent, "BackdropTemplate");
frame:SetSize(150, 46);
frame:SetFrameStrata("HIGH");
frame:SetClampedToScreen(true);
frame:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    edgeSize = 14,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
});
frame:SetBackdropColor(0, 0, 0, 0.8);
frame:SetBackdropBorderColor(0.6, 0.6, 0.6, 1);
frame:Hide();

local timeText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge");
timeText:SetPoint("TOP", 0, -8);

local countText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall");
countText:SetPoint("BOTTOM", 0, 8);

local function ApplyPosition()
    local pos = db.position or DEFAULT_POSITION;
    frame:ClearAllPoints();
    frame:SetPoint(pos.point, UIParent, pos.point, pos.x, pos.y);
end

frame:SetMovable(true);
frame:EnableMouse(true);
frame:RegisterForDrag("LeftButton");
frame:SetScript("OnDragStart", frame.StartMoving);
frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing();
    local point, _, _, x, y = self:GetPoint(1);
    db.position = { point = point, x = x, y = y };
    ApplyPosition();
end);

local function SetDisplay(seconds, crafts)
    timeText:SetText(FormatTime(seconds));
    countText:SetText(crafts == 1 and "last craft" or (crafts .. " crafts left"));
end

----------------------------------------------------------------------------
-- Queue tracking
----------------------------------------------------------------------------

local function EndQueue()
    state.casting = false;
    state.multi = false;
    state.lastEnd = nil;
    state.queueGap = nil;
    state.left = 0;
    state.shown = nil;
    if not state.preview then
        frame:Hide();
    end
end

local function UpdateTarget()
    local perCraft = (state.endTime - state.startTime) + (state.queueGap or 0);
    state.target = state.endTime + (state.left - 1) * perCraft;
end

local function SetLeft(left)
    state.left = left;
    if left > 1 then
        state.multi = true;
    end
    UpdateTarget();
end

local function Refresh()
    if state.preview then
        SetDisplay(754, 12);
        return;
    end

    local now = GetTime();
    if not state.casting then
        -- Pause between two crafts: keep counting down until the next cast
        -- starts, or give up when it does not.
        if now > state.gapDeadline then
            EndQueue();
            return;
        end
    else
        -- Around the start and end of a cast the game's own counter may or
        -- may not have counted the craft yet, so it is only trusted in the
        -- middle. In between, the count is kept by OnCastStart.
        local progress = (now - state.startTime) / (state.endTime - state.startTime);
        if progress > 0.25 and progress < 0.75 then
            local left = (C_TradeSkillUI.GetRemainingRecasts() or 0) + 1;
            if left ~= state.left then
                SetLeft(left);
                state.shown = nil;      -- a different number of crafts: no point easing into that
            end
        end
    end

    if not state.multi then
        return;     -- a single craft; the cast bar already covers that
    end

    if not state.shown then
        state.shown = state.target;
    else
        local dt = now - state.lastRefresh;
        local step = (state.target - state.shown) * math.min(1, dt / SLEW_TIME);
        local maxStep = dt * SLEW_MAX_RATE;
        state.shown = state.shown + math.max(-maxStep, math.min(maxStep, step));
    end
    state.lastRefresh = now;

    SetDisplay(math.max(0, state.shown - now), state.left);
    frame:Show();
end

local function OnCastStart()
    local name, _, _, startMs, endMs, isTradeSkill = UnitCastingInfo("player");
    if not name or not isTradeSkill or IsSecret(startMs) or IsSecret(endMs) then
        -- Casting anything else cancels a craft queue.
        EndQueue();
        return;
    end

    local continues = state.lastEnd ~= nil and state.left > 1;
    if not continues then
        EndQueue();
        if state.gapSamples > 0 then
            state.queueGap = state.gap;
        end
    end

    local oldTarget = state.target;
    state.casting = true;
    state.startTime = startMs / 1000;
    state.endTime = endMs / 1000;

    local gap;
    if continues then
        gap = state.startTime - state.lastEnd;
        if gap >= 0 and gap <= MAX_GAP then
            state.gapSamples = math.min(state.gapSamples + 1, GAP_SAMPLES);
            state.gap = state.gap + (gap - state.gap) / state.gapSamples;
            db.gap = state.gap;
            db.gapSamples = state.gapSamples;
            -- Nothing to go on from earlier queues: the first measurement
            -- has to do for this one.
            state.queueGap = state.queueGap or gap;
        end
        SetLeft(state.left - 1);
    else
        SetLeft((C_TradeSkillUI.GetRemainingRecasts() or 0) + 1);
    end

    if db.log then
        table.insert(db.log, string.format(
            "t=%.3f dur=%.3f gap=%s avg=%.3f used=%.3f left=%d api=%d shift=%s",
            state.startTime, state.endTime - state.startTime,
            gap and string.format("%.3f", gap) or "-", state.gap, state.queueGap or 0,
            state.left, C_TradeSkillUI.GetRemainingRecasts() or -1,
            continues and string.format("%+.3f", state.target - oldTarget) or "new"));
        while #db.log > LOG_SIZE do
            table.remove(db.log, 1);
        end
    end

    state.lastEnd = state.endTime;
    Refresh();
end

local function OnCastEnd()
    if not state.casting then
        return;
    end
    state.casting = false;
    if state.left > 1 then
        state.gapDeadline = GetTime() + GAP_GRACE;
    else
        EndQueue();
    end
end

----------------------------------------------------------------------------
-- Events
----------------------------------------------------------------------------

local elapsedSinceUpdate = 0;
frame:SetScript("OnUpdate", function(_, elapsed)
    elapsedSinceUpdate = elapsedSinceUpdate + elapsed;
    if elapsedSinceUpdate >= UPDATE_INTERVAL then
        elapsedSinceUpdate = 0;
        Refresh();
    end
end);

-- A separate frame for events, so they keep arriving while the display is hidden.
local events = CreateFrame("Frame");
events:RegisterEvent("ADDON_LOADED");
events:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON_NAME then
            return;
        end
        ZartockCraftingTimerDB = ZartockCraftingTimerDB or {};
        db = ZartockCraftingTimerDB;
        if type(db.gap) == "number" and db.gap >= 0 and db.gap <= MAX_GAP then
            state.gap = db.gap;
            state.gapSamples = math.max(1, math.min(tonumber(db.gapSamples) or 1, GAP_SAMPLES));
        end
        ApplyPosition();

        self:UnregisterEvent("ADDON_LOADED");
        self:RegisterUnitEvent("UNIT_SPELLCAST_START", "player");
        self:RegisterUnitEvent("UNIT_SPELLCAST_STOP", "player");
        self:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTED", "player");
        self:RegisterEvent("UPDATE_TRADESKILL_CAST_STOPPED");
    elseif event == "UNIT_SPELLCAST_START" then
        OnCastStart();
    elseif event == "UNIT_SPELLCAST_STOP" then
        OnCastEnd();
    else
        -- Interrupted (moved, cancelled, out of materials): the queue is gone.
        EndQueue();
    end
end);

----------------------------------------------------------------------------
-- Slash command
----------------------------------------------------------------------------

SLASH_ZARTOCKCRAFTINGTIMER1 = "/zct";
SlashCmdList.ZARTOCKCRAFTINGTIMER = function(msg)
    msg = strlower(strtrim(msg or ""));
    if msg == "reset" then
        db.position = nil;
        ApplyPosition();
        print("|cff33ff99Crafting Timer|r: position reset.");
        return;
    elseif msg == "log" then
        -- Records the timing of every craft in the saved variables, to find
        -- out why the timer misbehaves. Written to disk on /reload or logout.
        db.log = (not db.log) and {} or nil;
        print("|cff33ff99Crafting Timer|r: logging " .. (db.log and "on. /reload after a queue to save it." or "off, log deleted."));
        return;
    end

    state.preview = not state.preview;
    if state.preview then
        Refresh();
        frame:Show();
        print("|cff33ff99Crafting Timer|r: drag the timer where you want it, then type /zct again. /zct reset puts it back.");
    elseif not state.multi then
        frame:Hide();
    end
end;
