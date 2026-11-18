--  ===========================================================================
--  FSAC - Flight Stability Augmentation Computer
--  ===========================================================================
--  File        : software/core_spark/src/modes/fsac-modes.ads
--  Package     : Fsac.Modes  (specification)
--  Language    : Ada 2012 / SPARK 2014
--  Assurance   : DO-178C Software Level A (target), DO-333 formal supplement
--  SPARK_Mode  : On
--  Requirements: HLR-MOD-0001 .. HLR-MOD-0016 (placeholder IDs)
--  Decision    : ADR-012 (mode logic: demand and latch)
--
--  PURPOSE
--    Decides in which mode the computer operates, from the health evidence
--    the rest of the core publishes. The mode tells the control law how
--    boldly it may act: full authority when everything is healthy, reduced
--    gains and tighter limits as redundancy is lost, and finally a passive
--    hold when nothing can be controlled.
--
--  THE MODES, FROM BEST TO WORST (the order is the order of severity)
--
--      Normal        everything healthy, full authority
--      Degraded_1    one thing lost, still full authority (one sensor, one
--                    LRU, or one actuator path)
--      Degraded_2    reduced bandwidth and tighter limiters
--      Direct        fixed design-point gains, no scheduling, low authority
--      Fail_Passive  the control law is not executed; the surface is held
--
--  THE DESIGN IN ONE SENTENCE: DEMAND, THEN LATCH
--    Every frame, a PURE function Demand says which mode the current
--    conditions call for, with no memory. The mode then becomes
--    max (current mode, demand). Because the enumeration is ordered by
--    severity, the mode can only stay or get worse during a flight. It never
--    improves by itself. Only Reset (a ground maintenance action) returns it
--    to Normal.
--
--  WHY A ONE-WAY LATCH
--    A mode that moved up and down with the conditions would flicker at the
--    edge of a threshold and change the control law's gains many times a
--    second, which on an unstable airframe is itself a hazard. A failure
--    that has been confirmed is also not undone by a good moment: the sensor
--    that "recovered" is the marginal one. So the latch has no hysteresis
--    to tune because it has no way back.
--
--  WHAT CAN TRIGGER A MODE, AND WHY ONLY CONFIRMED CONDITIONS
--    A latch that reacted to a single bad frame would degrade the aircraft
--    for the rest of the flight because of a glitch. So every trigger is
--    either a CONFIRMED failure (a sensor is Failed, an LRU or actuator path
--    is lost) or a condition that PERSISTED for a number of frames
--    (counters below). Transient trouble is the job of the layers below: the
--    voter masks it, the damper holds its last command for up to
--    Hold_Count frames.
--
--  THE DEMAND TABLE (first row that matches wins, from the worst)
--
--    Fail_Passive   no usable sensor for Lost_Limit frames in a row, OR no
--                   healthy LRU
--    Direct         two or more sensors Failed (no cross-check left), OR
--                   only one healthy LRU (no consensus)
--    Degraded_2     disagreement left Unresolved for Unresolved_Limit frames,
--                   OR the surface sat at its limit for Saturation_Limit
--                   frames (authority lost), OR one sensor failed AND an
--                   actuator path degraded
--    Degraded_1     one sensor Failed, OR two healthy LRUs, OR one actuator
--                   path degraded
--    Normal         none of the above
--
--  TIME BUDGET (compile-time checked)
--    Lost_Limit is half of Max_Uncorrected_Frames (24 frames = 120 ms): the
--    hold lasts at most 12 frames (60 ms) before the passive reversion, and
--    the other half of the breakup time is margin for the reversion itself.
--
--  PROPERTIES PROVED (GNATprove)
--    D1  The mode never improves: new mode >= old mode.
--    D2  The mode is at least the demand of the updated counters and inputs,
--        and is exactly the larger of the old mode and that demand.
--    D3  Each counter counts consecutive frames of its condition, resets to
--        zero when the condition ends, and saturates (never wraps).
--    D4  After Lost_Limit consecutive frames without a usable sensor, the
--        mode is Fail_Passive.
--
--  CHECKED BY TESTS
--    Every row of the demand table, including the boundaries of each limit;
--    the profiles never increase authority as the mode worsens.
--
--  PLACEHOLDER VALUES
--    The limits (4, 10, 12 frames) and the scale factors are starting values
--    for the structure, not figures derived from a safety analysis. They are
--    to be replaced from the FDIR timing analysis (ADR-012).

with Fsac.Types; use Fsac.Types;
with Fsac.Control;
with Fsac.Control.Params;
with Fsac.Signal_Mgmt;
with Fsac.Signal_Mgmt.Cross_Check;

package Fsac.Modes
  with SPARK_Mode => On
is

   use type Fsac.Control.Loop_Status;
   use type Fsac.Signal_Mgmt.Sensor_Health;
   use type Fsac.Signal_Mgmt.Redundancy_Level;
   use type Fsac.Signal_Mgmt.Cross_Check.Decision;

   --  Modes

   type Mode is (Normal, Degraded_1, Degraded_2, Direct, Fail_Passive);
   --  Ordered from best to worst: "<" means "less severe".

   --  Persistence limits (frames of 5 ms)

   Unresolved_Limit : constant := 4;    --  20 ms of unresolved disagreement
   Saturation_Limit : constant := 10;   --  50 ms at the surface limit
   Lost_Limit       : constant := 12;   --  60 ms without a usable sensor

   pragma Compile_Time_Error
     (Lost_Limit * 2 > Max_Uncorrected_Frames,
      "Lost_Limit must leave half of the breakup time as margin");

   pragma Compile_Time_Error
     (Unresolved_Limit > Lost_Limit or else Saturation_Limit > Lost_Limit,
      "The soft triggers must act no later than the Fail_Passive trigger");

   subtype Frame_Run is Natural range 0 .. Max_Uncorrected_Frames;
   --  Consecutive frames of a condition. Saturates at its upper bound.

   function Next_Run (Old : Frame_Run; Condition : Boolean) return Frame_Run is
     (if Condition then
        (if Old < Frame_Run'Last then Old + 1 else Old)
      else
        0)
     with Global => null;
   --  Counts consecutive frames in which Condition holds.

   --  Inputs and state

   subtype Lru_Count is Natural range 0 .. Num_Lrus;
   subtype Failed_Count is Natural range 0 .. Sensors_Per_Measurement;

   function Count_Failed (H : Signal_Mgmt.Health_Set) return Failed_Count is
     ((if H (1) = Signal_Mgmt.Failed then 1 else 0)
      + (if H (2) = Signal_Mgmt.Failed then 1 else 0)
      + (if H (3) = Signal_Mgmt.Failed then 1 else 0))
     with Global => null;
   --  Number of sensors latched Failed (written out for three sensors).

   type Mode_Inputs is record
      Level             : Signal_Mgmt.Redundancy_Level;     --  from the voter
      Check_Result      : Signal_Mgmt.Cross_Check.Decision; --  from the voter
      Failed_Sensors    : Failed_Count;
      Loop_Status       : Control.Loop_Status;              --  from the damper
      Healthy_Lrus      : Lru_Count;                        --  from the consensus
      Actuator_Degraded : Boolean;                          --  from the actuator monitor
   end record;

   type Mode_State is record
      Current           : Mode;
      Unresolved_Frames : Frame_Run;
      Saturated_Frames  : Frame_Run;
      Lost_Frames       : Frame_Run;
   end record;

   Initial_State : constant Mode_State :=
     (Current           => Normal,
      Unresolved_Frames => 0,
      Saturated_Frames  => 0,
      Lost_Frames       => 0);

   --  Demand: what the conditions call for, with no memory

   function Demand
     (Unresolved : Frame_Run;
      Saturated  : Frame_Run;
      Lost       : Frame_Run;
      I          : Mode_Inputs) return Mode is
     (if Lost >= Lost_Limit or else I.Healthy_Lrus = 0 then
        Fail_Passive
      elsif I.Failed_Sensors >= 2 or else I.Healthy_Lrus = 1 then
        Direct
      elsif Unresolved >= Unresolved_Limit
        or else Saturated >= Saturation_Limit
        or else (I.Failed_Sensors = 1 and then I.Actuator_Degraded)
      then
        Degraded_2
      elsif I.Failed_Sensors = 1
        or else I.Healthy_Lrus = 2
        or else I.Actuator_Degraded
      then
        Degraded_1
      else
        Normal)
     with Global => null;

   --  The frame update (demand, then latch)

   procedure Update
     (State : in out Mode_State;
      I     : Mode_Inputs)
     with
       Global  => null,
       Depends => (State => (State, I)),
       Post    =>
         --  D3: the counters
         State.Unresolved_Frames =
           Next_Run (State'Old.Unresolved_Frames,
                     I.Check_Result = Signal_Mgmt.Cross_Check.Unresolved)
         and then State.Saturated_Frames =
           Next_Run (State'Old.Saturated_Frames,
                     I.Loop_Status = Control.Saturated)
         and then State.Lost_Frames =
           Next_Run (State'Old.Lost_Frames,
                     I.Level = Signal_Mgmt.Lost)

         --  D1: the mode never improves
         and then State.Current >= State'Old.Current

         --  D2: it is exactly the larger of the old mode and the demand
         and then State.Current =
           Mode'Max
             (State'Old.Current,
              Demand (State.Unresolved_Frames,
                      State.Saturated_Frames,
                      State.Lost_Frames,
                      I))

         --  D4: a long loss of every sensor ends in Fail_Passive
         and then
           (if State.Lost_Frames >= Lost_Limit then
              State.Current = Fail_Passive);

   procedure Reset (State : out Mode_State)
     with
       Global => null,
       Post   => State = Initial_State;
   --  Ground maintenance action only. The only way back to Normal.

   --  What each mode means for the control law

   subtype Scale_Factor is Q16 range 1 .. Q16_One_Raw;
   --  A multiplier in (0, 1].

   type Mode_Profile is record
      Gain_Scale  : Scale_Factor;   --  multiplies Kq and Ki_Dt
      Limit_Scale : Scale_Factor;   --  multiplies output and rate limits
      Scheduled   : Boolean;        --  False: use the fixed design-point gains
      Active      : Boolean;        --  False: the law is not run, surface held
   end record;

   function Profile_Of (M : Mode) return Mode_Profile is
     (case M is
        when Normal       => (Gain_Scale  => Q16_One_Raw,
                              Limit_Scale => Q16_One_Raw,
                              Scheduled   => True,
                              Active      => True),
        when Degraded_1   => (Gain_Scale  => Q16_One_Raw,
                              Limit_Scale => Q16_One_Raw,
                              Scheduled   => True,
                              Active      => True),
        when Degraded_2   => (Gain_Scale  => 45_875,      --  0.70
                              Limit_Scale => 45_875,
                              Scheduled   => True,
                              Active      => True),
        when Direct       => (Gain_Scale  => 32_768,      --  0.50
                              Limit_Scale => 32_768,
                              Scheduled   => False,
                              Active      => True),
        when Fail_Passive => (Gain_Scale  => 1,
                              Limit_Scale => 1,
                              Scheduled   => False,
                              Active      => False))
     with Global => null;
   --  Placeholder scales (see the header). The tests check that going to a
   --  worse mode never increases the gain or the authority.

   Gain_Floor : constant Control.Params.Surface_Limit := 6_554;
   --  0.10: a reduced Kq never goes below this (or below the base value).

   function Scaled_Params
     (Base : Control.Params.Pitch_Rate_Params;
      P    : Mode_Profile) return Control.Params.Pitch_Rate_Params
     with
       Global => null,
       Pre    => P.Active,
       Post   =>
         Scaled_Params'Result.Kq <= Base.Kq
         and then Scaled_Params'Result.Ki_Dt <= Base.Ki_Dt
         and then Scaled_Params'Result.Out_Limit <= Base.Out_Limit
         and then Scaled_Params'Result.Rate_Limit <= Base.Rate_Limit
         and then Scaled_Params'Result.Integrator_Limit <= Base.Integrator_Limit;
   --  The damper parameters for a mode: never more gain and never more
   --  authority than the base set, and always a VALID parameter set (the
   --  Pitch_Rate_Params predicate holds by construction).

   --  PRECONDITION: the profile must be Active. In Fail_Passive the law is
   --  not run and the surface is HELD at its last command. The scales of that
   --  profile mean "no authority at all"; applying them (or re-basing the
   --  damper state to them) would collapse the held command toward zero and
   --  drive the surface to neutral. The integration test IT-04 found exactly
   --  this mistake, so the contract now forbids it.

end Fsac.Modes;