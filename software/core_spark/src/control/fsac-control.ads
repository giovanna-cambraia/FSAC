--  ===========================================================================
--  FSAC - Flight Stability Augmentation Computer
--  ===========================================================================
--  File        : software/core_spark/src/control/fsac-control.ads
--  Package     : Fsac.Control (parent of all control-law units)
--  Language    : Ada 2012 / SPARK 2014
--  Assurance   : DO-178C Software Level A (target), DO-333 formal supplement
--  SPARK_Mode  : On
--  Requirements: HLR-CTL-0001 .. HLR-CTL-0003 (placeholder IDs)

-- PURPOSE
   -- parent package for everything under the control hierarchy:
   --   Fsac.Control.Params (gains, limits, schedule)
   --   Fsac.Control.Pitch_Rate_Damper (inner loop, pitch axis)
   --   later: roll and yaw dampers, outer loops
   -- it holds the few declarations that every control law shares, so the laws
   -- report their condition in the same vocabulary and the mode logic
   -- (Fsac.Modes, later) can treat them uniformly

-- WHY A PARENT PACKAGE AT ALL
   -- Ada child packages must have a parent; keeping real content here (and not
   -- an empty shell) gives one definition of "what a control law tells the
   -- rest of the system", instead of one per law

-- loop_Status
   -- every control step returns one of these values together with its command;
   -- the mode logic uses it to decide whether to stay in NORMAL or to
   -- reconfigure; the BIT/log partition records it
   --       Nominal        Output is the unconstrained result of the law.
   --       Rate_Limited   The surface rate limiter reduced the step. Expected
   --                      in strong manoeuvres, reported for monitoring.
   --       Saturated      The output hit the surface position limit.
   --                      Persistent saturation means loss of control
   --                      authority and is a reversion trigger (HLR-MOD-xxxx).
   --       Input_Invalid  The input was flagged invalid upstream (voter or
   --                      validity logic). The law held its last output and did
   --                      not integrate. It does not guess.

-- Hold_Count
   -- number of consecutive frames a law has held its output because inputs
   -- were invalid; its upper bound is Fsac.Max_Uncorrected_Frames
   -- (24 frames = 120 ms): holding longer than the structural breakup time
   -- is meaningless, so the type itself cannot represent it; the mode logic
   -- must have reverted long before the counter reaches the bound

package Fsac.Control
   with Pure, SPARK_Mode => On
is

   type Loop_Status is
     (Nominal, Rate_Limited, Saturated, Input_Invalid);

   subtype Hold_Count is Natural range 0 .. Max_Uncorrected_Frames;

end Fsac.Control;