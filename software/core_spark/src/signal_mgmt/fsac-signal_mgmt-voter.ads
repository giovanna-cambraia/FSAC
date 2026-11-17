--  ===========================================================================
--  FSAC - Flight Stability Augmentation Computer
--  ===========================================================================
--  File        : software/core_spark/src/signal_mgmt/fsac-signal_mgmt-voter.ads
--  Package     : Fsac.Signal_Mgmt.Voter  (specification)
--  Language    : Ada 2012 / SPARK 2014
--  Assurance   : DO-178C Software Level A (target), DO-333 formal supplement
--  SPARK_Mode  : On
--  Requirements: HLR-SIG-0035 .. HLR-SIG-0048 (placeholder IDs)
--  Decision    : ADR-003, ADR-009, ADR-010, ADR-011 (voter coupling rules)
--
--  PURPOSE
--    The one call per frame that turns three raw readings into ONE trusted
--    pitch rate for the control law, plus an honest statement of how much it
--    can be trusted. It joins the three signal-management units:
--
--       Cross_Check          finds the sensor that disagrees (with memory)
--       Mid_Value_Select     votes among the usable sensors
--       Observer             model-based third opinion
--
--  ONE FRAME, IN ORDER
--    1  Reference. The observer predicts the pitch rate of THIS frame from
--       the last estimate and the command sent last frame.
--    2  Cross_Check.Update compares the sensors (and, with two left, asks
--       the reference to break the tie). Health changes take effect now.
--    3  Mid_Value_Select.Vote picks the value from the usable sensors.
--    4  Duplex refinement (the reference-aided case, below).
--    5  Decide whether this frame's value is TRUSTED, and feed it to the
--       observer so the model stays anchored to real measurements.
--    6  Publish: value, effective redundancy level, and the evidence.
--
--  THE REFERENCE-AIDED CASE (why the voter does not wait for persistence)
--    With two usable sensors that disagree, the midpoint is wrong by half the
--    gap. Cross_Check needs Persistence frames before it EXCLUDES the bad
--    sensor, but the control law must not run on a contaminated midpoint in
--    the meantime. So as soon as Cross_Check LOCATES the outlier (using the
--    reference) while it is still usable, the voter publishes the OTHER
--    sensor's reading directly. The outlier is excluded from the VALUE
--    immediately and from the HEALTH set later, when its counter fills.
--    Because the value then rests on a single source, the published level is
--    Simplex, not Duplex: the level reports effective independent sources,
--    not the number of sensors that are merely not Failed.
--
--  WHEN IS A MEASUREMENT "TRUSTED" FOR THE OBSERVER?
--    Counting the sensors usable BEFORE this frame's update:
--      three usable, decision All_Agree or Located ... trusted
--          (the median masks one fault)
--      two usable,   decision All_Agree ............... trusted
--      anything else .............................. not trusted
--    In particular a reference-aided frame is NOT trusted. The reference
--    chose the sensor; letting that sensor correct the reference would make
--    the model confirm itself (positive feedback). Only evidence that does
--    not depend on the observer may feed the observer.
--
--  A COUPLING RULE THAT THE TYPE ENFORCES (ADR-011)
--    Once the observer stops being corrected (reference-aided frames are
--    untrusted) it ages one frame per frame, and its reference expires after
--    Max_Age frames. Cross_Check needs Persistence located frames to exclude
--    the outlier. If the reference expired first, the outlier could never be
--    excluded and the control law would drift back to the contaminated
--    midpoint. Therefore
--
--        Persistence - 1  <=  Max_Age
--
--    is a predicate of Voter_Params: a parameter set that breaks it cannot be
--    constructed. The two numbers look independent and are not.
--
--  PROPERTIES PROVED (GNATprove)
--    V1  Valid is exactly "Level is not Lost", and Lost means value 0.
--    V2  Without reference aid, the published value and level are exactly
--        those of Mid_Value_Select on the updated health.
--    V3  With reference aid, the level is Simplex, the decision was Located,
--        and the value is the reading of a usable sensor other than the
--        outlier.
--    V4  Trusted follows the rule above, and a trusted frame leaves the
--        observer initialized with age 0.
--    V5  The Cross_Check state stays consistent and Failed stays latched.
--
--  NOT COVERED HERE (so the mode logic must handle it)
--    Duplex with an unresolved disagreement and no usable reference (or a
--    reference far from both sensors): the value is the midpoint, which may be
--    wrong by half the gap. It is published with Check.Result = Unresolved.
--    The mode logic treats that as a degradation event.

with Fsac.Signal_Mgmt.Cross_Check;
with Fsac.Signal_Mgmt.Mid_Value_Select;
with Fsac.Signal_Mgmt.Observer;

package Fsac.Signal_Mgmt.Voter
  with SPARK_Mode => On
is

   --  Makes "=" on the Cross_Check decisions visible here and in the body.
   use type Cross_Check.Decision;

   --  Parameters and state

   type Voter_Params is record
      Check : Cross_Check.Check_Params;
      Obs   : Observer.Observer_Params;
   end record
     with Dynamic_Predicate =>
       Voter_Params.Check.Persistence - 1 <= Voter_Params.Obs.Max_Age;
   --  ADR-011: the reference must outlive the time needed to exclude a sensor.

   --  Expression function so no library-level elaboration code is generated
   --  for the default object; the predicate is checked at each call.
   function Default_Params return Voter_Params is
     (Check => (Threshold   => Cross_Check.Default_Threshold,
                Persistence => Cross_Check.Default_Persistence),
      Obs   => Observer.Default_Params);

   type Voter_State is record
      Check : Cross_Check.Check_State;
      Obs   : Observer.Observer_State;
   end record;

   --  Same reasoning as Default_Params: an expression function avoids
   --  elaboration of a constant whose components may themselves not be
   --  static.
   function Initial_State return Voter_State is
     (Check => Cross_Check.Initial_State,
      Obs   => Observer.Initial_State);

   --  What one frame publishes

   type Voted is record
      Value   : Body_Rate;
      Level   : Redundancy_Level;   --  EFFECTIVE independent sources
      Valid   : Boolean;            --  False exactly when Level = Lost
      Trusted : Boolean;            --  this value was fed to the observer
      Aided   : Boolean;            --  the reference chose the value
      Check   : Cross_Check.Check_Report;
   end record;

   --  The frame step

   procedure Step
     (State    : in out Voter_State;
      Params   : Voter_Params;
      R        : Reading_Set;
      Cmd_Prev : Surface_Cmd;
      Output   : out Voted)
     with
       Global  => null,
       Depends =>
         (State  => (State, Params, R, Cmd_Prev),
          Output => (State, Params, R, Cmd_Prev)),
       Pre     => Cross_Check.Consistent (State.Check, Params.Check),
       Post    =>
         --  V5: consistency and the latch
         Cross_Check.Consistent (State.Check, Params.Check)
         and then
           (for all I in Sensor_Id =>
              (if State'Old.Check (I).Health = Failed then
                 State.Check (I).Health = Failed))

         --  V1: validity and the empty case
         and then Output.Valid = (Output.Level /= Lost)
         and then (if Output.Level = Lost then Output.Value = 0)

         --  V2: without aid, exactly the vote on the updated health
         and then
           (if not Output.Aided then
              Output.Level =
                Mid_Value_Select.Vote
                  (R, Cross_Check.Health_Of (State.Check)).Level
              and then Output.Value =
                Mid_Value_Select.Vote
                  (R, Cross_Check.Health_Of (State.Check)).Value)

         --  V3: with aid, one source, located outlier, value from another
         and then
           (if Output.Aided then
              Output.Level = Simplex
              and then Output.Check.Result = Cross_Check.Located
              and then
                (for some J in Sensor_Id =>
                   J /= Output.Check.Outlier
                   and then Usable
                              (R (J),
                               Cross_Check.Health_Of (State.Check) (J))
                   and then Output.Value = R (J).Value))

         --  V4: the trust rule, counted on the sensors usable BEFORE the frame
         and then
           (Output.Trusted =
              ((Mid_Value_Select.Count_Usable
                  (R, Cross_Check.Health_Of (State'Old.Check)) = 3
                and then
                  (Output.Check.Result = Cross_Check.All_Agree
                   or else Output.Check.Result = Cross_Check.Located))
               or else
                 (Mid_Value_Select.Count_Usable
                    (R, Cross_Check.Health_Of (State'Old.Check)) = 2
                  and then Output.Check.Result = Cross_Check.All_Agree)))
         and then
           (if Output.Trusted then
              State.Obs.Initialized and then State.Obs.Age = 0);

end Fsac.Signal_Mgmt.Voter;