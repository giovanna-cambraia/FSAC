--  ===========================================================================
--  FSAC - Flight Stability Augmentation Computer
--  ===========================================================================
--  File        : software/core_spark/src/signal_mgmt/fsac-signal_mgmt-cross_check.ads
--  Package     : Fsac.Signal_Mgmt.Cross_Check  (specification)
--  Language    : Ada 2012 / SPARK 2014
--  Assurance   : DO-178C Software Level A (target), DO-333 formal supplement
--  SPARK_Mode  : On
--  Requirements: HLR-SIG-0013 .. HLR-SIG-0024 (placeholder IDs)
--  Decision    : ADR-003, ADR-009 (persistence and threshold, see below)
--
--  PURPOSE
--    Fault detection and isolation (FDIR) for one set of three redundant
--    sensors. Mid_Value_Select hides a fault from the control law; this
--    package FINDS it, so the sensor can be excluded before a second fault
--    arrives. Once two sensors are bad, no vote can rescue the output.
--
--  THE KEY TIMING IDEA (why persistence is not a safety-critical number
--  by itself)
--    With three usable sensors the median already masks one fault from the
--    very first frame (property M1). Detection speed therefore does NOT
--    decide whether the airframe survives the first fault. What it decides
--    is the "latent window": how long the system runs with a known-bad
--    sensor still voting, during which a SECOND fault would defeat the vote.
--    So the persistence time is a trade between
--      too short : noise or a gust trips a good sensor, wasting redundancy
--      too long  : the latent window grows
--    ADR-009 records the chosen values and the reasoning.
--
--  THE ALGORITHM, ONE FRAME (a small state machine)
--
--   Step 1  Who takes part? Only USABLE sensors: valid (from the bridge) and
--           not already Failed.
--   Step 2  Compare the usable sensors with each other. Two readings AGREE
--           when they differ by no more than Threshold.
--           Three usable sensors:
--             all three pairs agree ............ All_Agree
--             exactly one sensor disagrees with both of the others, and
--             those two agree with each other .. Located (that sensor)
--             any other pattern (a chain 1~2~3, or nobody agrees)
--                                                Unresolved
--           Two usable sensors:
--             they agree ........................ All_Agree
--             they disagree AND the analytical reference is valid AND
--             exactly one of them agrees with the reference
--                                                Located (the other one)
--             any other case ................... Unresolved
--           One or none usable: nothing to compare ... Insufficient
--   Step 3  Update the disagreement counters (a leaky bucket):
--             All_Agree : every usable sensor counts down by 1 (minimum 0)
--             Located   : the outlier counts up by 1, the others down by 1
--             Unresolved, Insufficient : nothing changes (no evidence)
--   Step 4  Health follows the counter:
--             count = 0 ............................ Healthy
--             0 < count < Persistence .............. Suspect (still used)
--             count reaches Persistence ............ Failed (LATCHED)
--
--  WHY A LEAKY BUCKET AND NOT "N FRAMES IN A ROW"
--    A sensor that fails intermittently (bad one frame, fine the next)
--    would reset a consecutive-frames counter forever and never be caught.
--    The bucket fills by 1 on every miscompare and drains by 1 on every
--    agreement, so any sensor that is wrong more than half of the time is
--    caught, while a one-off glitch drains away on its own. (A sensor wrong
--    exactly half of the time stays at the same level and is NOT caught: a
--    known limit, accepted and recorded in ADR-009.)
--
--  WHY "UNRESOLVED" CHANGES NOTHING
--    If the data cannot say who is wrong (two sensors disagree and there is
--    no reference, or all three disagree), blaming anyone would be a guess.
--    A wrong guess excludes a good sensor and wastes redundancy. The event is
--    reported (Decision = Unresolved) so the mode logic can react.
--
--  THE REFERENCE (analytical channel, ADR-003)
--    With only two sensors left, the sensors alone cannot say who is right.
--    The Observer provides a model-based estimate. It is used ONLY to
--    choose between two disagreeing sensors, and only when EXACTLY ONE of
--    them is close to it. If the reference is far from both or close to
--    both, nobody is blamed. A wrong observer can therefore never exclude a
--    sensor on its own.
--
--  PROPERTIES PROVED (GNATprove)
--    X1  The state stays consistent: Healthy means count 0, Suspect means
--        0 < count < Persistence.
--    X2  Failed is latched: a Failed sensor is Failed in the next frame.
--    X3  A sensor becomes Failed only when the decision was Located, it is
--        the located outlier, and its counter reached Persistence.
--    X4  A located outlier was usable, and differs by more than Threshold
--        from every OTHER usable sensor. Nobody is blamed who agrees with
--        another usable sensor.
--    X5  Insufficient and Unresolved leave the whole state unchanged.
--    X6  The decision is Insufficient exactly when fewer than two sensors
--        are usable.
--    X7  Newly_Failed is reported exactly when a sensor changed to Failed.
--
--  CONNECTION TO THE VOTER
--    Health_Of turns the state into the Health_Set that Mid_Value_Select
--    consumes, so the exclusion decided here takes effect in the same frame
--    it is made (the voter is called after the update).
--
--  TIMING SHAPE
--    No loops. Three helper calls and a fixed number of comparisons.

with Fsac.Signal_Mgmt.Mid_Value_Select;

package Fsac.Signal_Mgmt.Cross_Check
  with SPARK_Mode => On
is

   --  Parameters

   subtype Persistence_Frames is Positive range 1 .. Max_Uncorrected_Frames;
   --  the counter limit can never exceed the structural breakup time in
   --  frames (24 = 120 ms): a longer persistence would be meaningless

   subtype Disagree_Count is Natural range 0 .. Max_Uncorrected_Frames;

   subtype Rate_Threshold is Q16 range 1 .. Body_Rate_Max_Raw;
   --  largest difference (rad/s) at which two readings still agree

   type Check_Params is record
      Threshold   : Rate_Threshold;
      Persistence : Persistence_Frames;
   end record;

   Default_Threshold   : constant Rate_Threshold := 6_554;   --  0.10 rad/s
   Default_Persistence : constant Persistence_Frames := 8;   --  8 frames = 40 ms
   --  starting values (ADR-009); they are design parameters: replace them with
   --  the figures from the sensor error budget and the FDIR timing analysis

   --  state

   type Sensor_State is record
      Health : Sensor_Health;
      Count  : Disagree_Count;
   end record;

   type Check_State is array (Sensor_Id) of Sensor_State;

   Initial_State : constant Check_State :=
     (others => (Health => Healthy, Count => 0));

   function Consistent_One
     (S           : Sensor_State;
      Persistence : Persistence_Frames) return Boolean is
     (case S.Health is
        when Healthy => S.Count = 0,
        when Suspect => S.Count >= 1 and then S.Count < Persistence,
        when Failed  => True)
     with Global => null;

   function Consistent
     (State  : Check_State;
      Params : Check_Params) return Boolean is
     (for all I in Sensor_Id =>
        Consistent_One (State (I), Params.Persistence))
     with Global => null;

   function Health_Of (State : Check_State) return Health_Set is
     ((1 => State (1).Health,
       2 => State (2).Health,
       3 => State (3).Health))
     with Global => null;
   --  the health values in the form the voter consumes

   --  inputs and outputs of one frame

   type Reference is record
      Value : Body_Rate;   --  model-based estimate of the same quantity
      Valid : Boolean;     --  False when the analytical channel is not available
   end record;

   type Decision is (Insufficient, All_Agree, Located, Unresolved);

   type Check_Report is record
      Result       : Decision;
      Outlier      : Sensor_Id;   --  meaningful only when Result = Located
      Newly_Failed : Boolean;     --  some sensor became Failed in this frame
   end record;

   function Differ
     (A, B : Body_Rate;
      T    : Rate_Threshold) return Boolean is
     (abs (Wide (A) - Wide (B)) > Wide (T))
     with Global => null;
   --  the two readings disagree (differ by MORE than the threshold)

   --  the frame update

   procedure Update
     (State  : in out Check_State;
      Params : Check_Params;
      R      : Reading_Set;
      Ref    : Reference;
      Report : out Check_Report)
     with
       Global  => null,
       Depends =>
         (State  => (State, Params, R, Ref),
          Report => (State, Params, R, Ref)),
       Pre     => Consistent (State, Params),
       Post    =>
         --  X1: consistency is kept
         Consistent (State, Params)

         --  X6: the decision is Insufficient exactly when fewer than two sensors are usable
         and then
           ((Report.Result = Insufficient) =
              (Mid_Value_Select.Count_Usable (R, Health_Of (State'Old)) < 2))

         --  X2: Failed is latched
         and then
           (for all I in Sensor_Id =>
              (if State'Old (I).Health = Failed then
                 State (I).Health = Failed))

         --  X5: no evidence, no change
         and then
           (if Report.Result = Insufficient or else Report.Result = Unresolved
            then State = State'Old)

         --  X4: a located outlier was usable and disagrees with every other usable sensor
         and then
           (if Report.Result = Located then
              Usable (R (Report.Outlier), State'Old (Report.Outlier).Health)
              and then
                (for all J in Sensor_Id =>
                   (if J /= Report.Outlier
                      and then Usable (R (J), State'Old (J).Health)
                    then
                      Differ (R (J).Value, R (Report.Outlier).Value,
                              Params.Threshold))))

         --  X3: becoming Failed needs a located outlier at the limit
         and then
           (for all I in Sensor_Id =>
              (if State'Old (I).Health /= Failed
                 and then State (I).Health = Failed
               then
                 Report.Result = Located
                 and then Report.Outlier = I
                 and then State (I).Count = Params.Persistence))

         --  X7: the flag tells the truth
         and then
           (Report.Newly_Failed =
              (for some I in Sensor_Id =>
                 State'Old (I).Health /= Failed
                 and then State (I).Health = Failed));

end Fsac.Signal_Mgmt.Cross_Check;