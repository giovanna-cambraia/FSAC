--  ===========================================================================
--  FSAC - Flight Stability Augmentation Computer
--  ===========================================================================
--  File        : software/core_spark/src/fsac.ads
--  Package     : Fsac (root of the hierarchy)
--  Language    : Ada 2012 / SPARK 2014
--  Assurance   : DO-178C Software Level A (target), DO-333 formal supplement
--  SPARK_Mode  : On
--  Requirements: HLR-SYS-0001 .. HLR-SYS-0004

-- PURPOSE
   -- root package for every Ada unit in the stabilization core, it holds no
   -- executable code, it only declares the system-wide constants that other
   -- packages depend on, so each timing and redundancy number exists in exactly
   -- one place and can be traced to one requirement

-- DESIGN NOTES
   -- * pure: no state, no elaboration code, no dependencies; every child
   -- package can "with" it without creating dependency cycle
   -- * values are Ada named numbers (universal integers, they have no memory
   -- representation and cannot overflow; child packages convert them to
   -- concrete types where needed
   -- * consistency between related constants is checked at compile time with
   -- pragma Compile_Time_Error, so an edit that breaks the timing model fails
   -- the build instead of reaching a test branch

-- TRACEABILITY
   --    Frame_Rate_Hz, Frame_Period_Us ........ SYS-TIM-0001  (>= 200 Hz loop)
   --    Inner_Loop_WCET_Budget_Us ............. SYS-TIM-0002  (<= 1.8 ms WCET)
   --    Max_Jitter_Us ......................... SYS-TIM-0003  (<= 25 us)
   --    Structural_Breakup_Limit_Ms ........... SYS-SAF-0001  (< 120 ms)
   --    Num_Lrus, Sensors_Per_Measurement ..... ADR-001, ADR-003

-- CHANGE POLICY
   -- any change to this file is a DAL-A change: independent review and a full
   -- regression run are required (see ci/gates.yaml)

package Fsac
   with Pure, SPARK_Mode => On
is

   -- timing model (part 1, section 4)

   Frame_Rate_Hz   : constant := 200;
   -- inner-loop execution rate; one minor frame per iteration

   Frame_Period_Us : constant := 5_000;
   -- minor-frame period in microseconds (1 / 200 Hz)

   Major_Frame_Ms  : constant := 20;
   -- ARINC 653 major frame; four minor frames per major frame

   Inner_Loop_WCET_Budget_Us : constant := 1_800;
   -- hard budget for the whole sensor-to-actuator chain inside one minor frame
   -- (windows W1..W6 of the schedule); verified by static WCET analysis plus
   -- on-target measurement

   Max_Jitter_Us   : constant := 25;
   -- maximum allowed variation of the frame start instant

   -- safety timing

   Structural_Breakup_Limit_Ms : constant := 120;
   -- time after which uncorrected divergence can break up the airframe

   Max_Uncorrected_Frames : constant :=
     (Structural_Breakup_Limit_Ms * 1_000) / Frame_Period_Us;
   -- upper bound on consecutive frames without a valid control output
   -- (24 frames); fault-detection and reversion latencies are budgeted
   -- against this number

   -- redundancy structure (ADR-001, ADR-003)

   Num_Lrus : constant := 3;
   -- FSAC LRUs (channel A, B, C); a fourth is reserved as a growth option

   Sensors_Per_Measurement : constant := 3;
   -- physical sensors per critical measurement, a model-based analytical
   -- channel acts as the fourth voter (ADR-003)

   -- compile-time consistency checks

   pragma Compile_Time_Error
     (Frame_Rate_Hz * Frame_Period_Us /= 1_000_000,
      "Frame_Rate_Hz and Frame_Period_Us are inconsistent");

   pragma Compile_Time_Error
     (Major_Frame_Ms * 1_000 mod Frame_Period_Us /= 0,
      "Major frame must be a whole number of minor frames");

   pragma Compile_Time_Error
     (Inner_Loop_WCET_Budget_Us > Frame_Period_Us,
      "WCET budget exceeds the minor-frame period");

   pragma Compile_Time_Error
     (Max_Jitter_Us * 100 > Frame_Period_Us,
      "Jitter allowance exceeds 1 percent of the frame period");

   pragma Compile_Time_Error
     (Max_Uncorrected_Frames < 1,
      "Breakup limit shorter than one frame");

end Fsac;