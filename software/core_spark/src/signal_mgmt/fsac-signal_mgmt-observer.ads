--  ===========================================================================
--  FSAC - Flight Stability Augmentation Computer
--  ===========================================================================
--  File        : software/core_spark/src/signal_mgmt/fsac-signal_mgmt-observer.ads
--  Package     : Fsac.Signal_Mgmt.Observer  (specification)
--  Language    : Ada 2012 / SPARK 2014
--  Assurance   : DO-178C Software Level A (target), DO-333 formal supplement
--  SPARK_Mode  : On
--  Requirements: HLR-SIG-0025 .. HLR-SIG-0034 (placeholder IDs)
--  Decision    : ADR-003 (analytical redundancy), ADR-010 (observer design)
--
--  PURPOSE
--    The analytical channel: a small model of the airframe that keeps its own
--    estimate of the pitch rate, built from what the system already knows
--    (the surface command it sent, and the measurements it trusts). Its only
--    job is to be a THIRD OPINION when just two sensors are left and they
--    disagree (see Cross_Check, "The Reference"). It never replaces a sensor
--    and never decides alone.
--
--  THE MODEL (one frame, all in Q16 integer arithmetic)
--
--      predicted  P  =  A * estimate  +  B * command
--
--    A is the free response of the airframe over one frame (slightly above
--    1.0 for an UNSTABLE airframe: left alone, the rate grows). B says how
--    much one unit of surface command changes the rate in one frame.
--
--      when a TRUSTED measurement m is available:
--         estimate' = P + L * (m - P)         0 <= L <= 1, "the correction"
--         age'      = 0
--      when it is not:
--         estimate' = P                        (dead reckoning)
--         age'      = age + 1, saturating
--
--    This is a Luenberger observer in its simplest form. L = 0 would ignore
--    the measurements (pure model, drifts away); L = 1 would copy the
--    measurement (pure sensor). In between, the model smooths and the
--    measurement keeps it honest.
--
--  WHY AN UNSTABLE AIRFRAME MAKES THE OBSERVER DANGEROUS (and what is done)
--    With A > 1 the model's own error grows with every frame without
--    correction. A long dead-reckoning run would produce a confident, wrong
--    number. Three guards keep that from ever being used:
--      G1  AGE: the reference is VALID only while age <= Max_Age frames since
--          the last trusted measurement (Max_Age is capped by the
--          structural breakup time in frames). Beyond that it says "I do not
--          know" instead of guessing.
--      G2  CLAMPED: the estimate is clamped to the Body_Rate range, so it can
--          never exceed what the rest of the core accepts.
--      G3  NO INTEGRATOR: the model has no accumulating state besides the
--          estimate itself, so there is nothing to wind up.
--    And outside this package: the Cross_Check uses the reference only to
--    choose between two disagreeing sensors, and only when exactly one of
--    them is close to it. A wrong observer therefore cannot exclude a sensor
--    on its own.
--
--  WHAT "TRUSTED" MEANS (decided by the caller, the Voter)
--    The measurement is trusted only when it came from a vote that a single
--    fault cannot have corrupted: three usable sensors, or two that agree.
--    In particular, a duplex miscompare is NOT trusted: the midpoint of a good
--    and a bad sensor would pull the observer toward the bad one and
--    destroy the very tie-break it exists to provide.
--
--  STEADY-STATE BIAS (a property to understand, not a bug)
--    For a constant trusted measurement m the estimate settles at
--
--        estimate = L * m / (1 - (1 - L) * A)
--
--    which equals m only when A = 1. With the placeholder values (A = 1.01,
--    L = 0.3) it settles at 1.024 * m, i.e. 2.4 percent above the
--    measurement. The model's mild instability leaks into the estimate. This
--    is harmless for a tie-break (the threshold of Cross_Check is far larger),
--    but it is the reason L must not be chosen too small: the bias grows as
--    L falls. The tests pin this number so a change of A or L is noticed.
--
--  THE CORRECTION CANNOT OVERSHOOT
--    The corrected estimate is clamped between the prediction and the
--    measurement. Truncation in the product can never push it outside that
--    interval, and the proof does not depend on the solver's mood (the same
--    trade made in Gain_Schedule.Interpolate).
--
--  PROPERTIES PROVED (GNATprove)
--    O1  With a trusted measurement: initialized, age 0, and the new estimate
--        lies between the prediction and the measurement.
--    O2  Without one: the new estimate IS the prediction (dead reckoning),
--        initialization is unchanged, and age grows by 1 up to its cap.
--    O3  The estimate is always inside the Body_Rate range (by its type).
--
--  CHECKED BY TESTS
--    The reference becomes invalid exactly Max_Age + 1 untrusted frames after
--    the last trusted one; convergence toward a constant measurement; the
--    effect of the command on the prediction.
--
--  PLACEHOLDER VALUES
--    A, B and L below are NOT identified from a real airframe. They are
--    starting values so the code runs and is tested. Replace them with the
--    values from the plant identification (models/plant_6dof/).

with Fsac.Signal_Mgmt.Cross_Check;
with Fsac.Signal_Mgmt.Mid_Value_Select;

package Fsac.Signal_Mgmt.Observer
  with SPARK_Mode => On
is

   --  Parameters

   subtype Model_Coeff is Q16 range -(2 * Q16_One_Raw) .. 2 * Q16_One_Raw;
   --  A and B, within +-2.0

   subtype Unit_Gain is Q16 range 0 .. Q16_One_Raw;
   --  The correction gain L, 0.0 .. 1.0

   subtype Age_Frames is Natural range 0 .. Max_Uncorrected_Frames;
   subtype Max_Age_Frames is Positive range 1 .. Max_Uncorrected_Frames;
   --  the age limit can never exceed the structural breakup time in frames

   type Observer_Params is record
      A       : Model_Coeff;      --  free response over one frame
      B       : Model_Coeff;      --  effect of one unit of surface command
      L       : Unit_Gain;        --  correction gain
      Max_Age : Max_Age_Frames;   --  frames the reference may run uncorrected
   end record;

   Default_Params : constant Observer_Params :=
     (A       => 66_191,   --  1.01 (mildly unstable)
      B       => 6_554,    --  0.10 rad/s per frame per unit of command
      L       => 19_661,   --  0.30
      Max_Age => 8);
   --  placeholders, see the header

   --  state

   type Observer_State is record
      Estimate    : Body_Rate;
      Age         : Age_Frames;   --  frames since the last trusted measurement
      Initialized : Boolean;      --  False until the first trusted measurement
   end record;

   Initial_State : constant Observer_State :=
     (Estimate => 0, Age => Age_Frames'Last, Initialized => False);

   --  what the rest of the system sees

   function Reference_Valid
     (S : Observer_State;
      P : Observer_Params) return Boolean is
     (S.Initialized and then S.Age <= P.Max_Age)
     with Global => null;
   --  True only while the estimate is fresh enough to be a third opinion

   function Reference_Of
     (S : Observer_State;
      P : Observer_Params) return Cross_Check.Reference is
     (Value => S.Estimate, Valid => Reference_Valid (S, P))
     with Global => null;
   --  the estimate in the form Cross_Check.Update consumes

   --  The model step

   function Predict
     (S   : Observer_State;
      P   : Observer_Params;
      Cmd : Surface_Cmd) return Body_Rate
     with Global => null;
   --  a * estimate + B * command, saturated and clamped to Body_Rate

   procedure Update
     (S       : in out Observer_State;
      P       : Observer_Params;
      Cmd     : Surface_Cmd;
      Meas    : Body_Rate;
      Trusted : Boolean)
     with
       Global  => null,
       Depends => (S => (S, P, Cmd, Meas, Trusted)),
       Post    =>
         (if Trusted then
            --  O1
            S.Initialized
            and then S.Age = 0
            and then Mid_Value_Select.Within
                       (S.Estimate, Predict (S'Old, P, Cmd), Meas)
          else
            --  O2
            S.Estimate = Predict (S'Old, P, Cmd)
            and then S.Initialized = S'Old.Initialized
            and then S.Age =
              (if S'Old.Age < Age_Frames'Last then S'Old.Age + 1
               else Age_Frames'Last));
   --  cmd is the surface command issued in the PREVIOUS frame (the one whose
   --  effect Meas now reflects); Meas is used only when Trusted

end Fsac.Signal_Mgmt.Observer;