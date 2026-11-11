--  ===========================================================================
--  FSAC - Flight Stability Augmentation Computer
--  ===========================================================================
--  File        : software/core_spark/src/types/fsac-types.ads
--  Package     : Fsac.Types
--  Language    : Ada 2012 / SPARK 2014
--  Assurance   : DO-178C Software Level A (target), DO-333 formal supplement
--  SPARK_Mode  : On
--  Requirements: HLR-NUM-0001 .. HLR-NUM-0006 (placeholder IDs)
--  Decision    : ADR-005 (fixed-point arithmetic in the inner loop)

--  PURPOSE
   -- defines every numeric type and enumeration that crosses a package boundary
   -- in the stabilization core; a signal such as pitch rate is a distinct
   -- subtype with a physical range, so the compiler and the prover know its
   -- bounds everywhere it is used

--  NUMBER REPRESENTATION: Q16.16
   -- a Q16 value is a 32-bit signed integer holding (real_value * 2**16)
   --       resolution   : 2**-16 = 0.0000153
   --       range        : about -32768.0 .. +32767.99998 (symmetric, see below)
   --       real 1.0     : raw 65_536
   -- only integer arithmetic is executed at run time; results are bit-exact
   -- across the command lane, the monitor lane, the SIL simulation and the
   -- hardware test bench, which is what makes cross-lane comparison and
   -- requirements-based testing deterministic

--  WHY THE RANGE IS SYMMETRIC
   -- the range excludes -2**31. With it, "abs X" and "-X" would overflow for
   -- the most negative value, and the prover would require a proof obligation
   -- at every use; excluding it removes that whole class of run-time error by
   -- construction

--  HOW TO WRITE A CONSTANT
   -- use a static conversion so the real number is visible in the source and
   -- the integer is computed at compile time:
   --        Kq : constant Gain := Gain (2.5 * Q16_Scale_Real);

--  WIDE TYPE
   -- wide is the 64-bit type used only for intermediate products, the product
   -- of two Q16 values is below 2**62, which fits in Wide; Fixed_Math is the
   -- only package that is meant to use Wide.

--  PHYSICAL UNITS (all values are Q16 unless stated)
   --    Body_Rate ........ rad/s       +-8.0
   --    Rate_Error ....... rad/s       +-16.0
   --    Angle_Of_Attack .. rad         +-1.0
   --    Load_Factor ...... g           +-16.0
   --    Dyn_Pressure ..... kPa         0.0 .. 128.0
   --    Mach_Number ...... (none)      0.0 .. 4.0
   --    Surface_Cmd ...... fraction    +-1.0 of full surface travel
   --    Gain ............. (none)      0.0 .. 16.0

--  CHANGE POLICY
   -- changing a range is a DAL-A change, it invalidates saved proof sessions
   -- of every unit that uses the type, so rerun GNATprove on the whole core

package Fsac.Types
  with Pure, SPARK_Mode => On
is

   --  Q16.16 representation
   Q16_Frac_Bits  : constant := 16;
   Q16_One_Raw    : constant := 2**Q16_Frac_Bits;
   Q16_Scale_Real : constant := 65_536.0;
   --  multiply a real literal by this to obtain the raw integer value

   Q16_Max_Raw    : constant := 2**31 - 1;

   type Q16 is range -Q16_Max_Raw .. Q16_Max_Raw;
   for Q16'Size use 32;

   type Wide is range -(2**63 - 1) .. 2**63 - 1;
   for Wide'Size use 64;
   --  intermediate product type

   Q16_Zero : constant Q16 := 0;
   Q16_One  : constant Q16 := Q16_One_Raw;

   --  physical limits, expressed as raw values so they are static
   Body_Rate_Max_Raw    : constant := 8 * Q16_One_Raw;     --  8.0 rad/s
   Rate_Error_Max_Raw   : constant := 16 * Q16_One_Raw;    --  16.0 rad/s
   Alpha_Max_Raw        : constant := Q16_One_Raw;         --  1.0 rad
   Load_Factor_Max_Raw  : constant := 16 * Q16_One_Raw;    --  16.0 g
   Dyn_Pressure_Max_Raw : constant := 128 * Q16_One_Raw;   --  128.0 kPa
   Mach_Max_Raw         : constant := 4 * Q16_One_Raw;     --  4.0
   Surface_Cmd_Max_Raw  : constant := Q16_One_Raw;         --  1.0 (full travel)
   Gain_Max_Raw         : constant := 16 * Q16_One_Raw;    --  16.0

   --  physical quantities
   subtype Body_Rate is Q16
     range -Body_Rate_Max_Raw .. Body_Rate_Max_Raw;
   --  angular rate about a body axis, rad/s, after validity checking

   subtype Rate_Error is Q16
     range -Rate_Error_Max_Raw .. Rate_Error_Max_Raw;
   --  difference of two Body_Rate values; twice the range, so the subtraction
   --  of two valid rates can never leave the subtype

   subtype Angle_Of_Attack is Q16
     range -Alpha_Max_Raw .. Alpha_Max_Raw;

   subtype Load_Factor is Q16
     range -Load_Factor_Max_Raw .. Load_Factor_Max_Raw;

   subtype Dyn_Pressure is Q16
     range 0 .. Dyn_Pressure_Max_Raw;
   --  dynamic pressure in kPa; pascals would not fit in Q16

   subtype Mach_Number is Q16
     range 0 .. Mach_Max_Raw;

   subtype Surface_Cmd is Q16
     range -Surface_Cmd_Max_Raw .. Surface_Cmd_Max_Raw;
   --  normalized surface command: -1.0 .. +1.0 of full travel; the actuator
   --  driver scales it to engineering units and electrical drive

   subtype Gain is Q16
     range 0 .. Gain_Max_Raw;
   --  non-negative controller gain; negative feedback is expressed by the
   --  structure of the control law, not by a negative gain value

   --  structural enumerations and index types
   type Axis is (Pitch, Roll, Yaw);

   type Lane_Id is (Lane_A, Lane_B, Lane_C);
   --  One per FSAC LRU (ADR-001).

   Sensors_Per_Measurement : constant := 3;
   --  redundant sensor configuration (ADR-003)

   subtype Sensor_Id is Positive range 1 .. Sensors_Per_Measurement;
   --  index of a physical sensor within one redundant set (ADR-003)

   type Frame_Count is mod 2**32;
   --  free-running minor-frame counter; wraps after about 248 days of
   --  continuous operation; all uses must compare differences, never
   --  absolute values

   --  compile-time checks that the numeric model is sound
   pragma Compile_Time_Error
     (Q16_Max_Raw * Q16_Max_Raw > 2**62,
      "Product of two Q16 values no longer fits in Wide with margin");

   pragma Compile_Time_Error
     (Rate_Error_Max_Raw < 2 * Body_Rate_Max_Raw,
      "Rate_Error must cover the difference of two Body_Rate values");

   pragma Compile_Time_Error
     (Gain_Max_Raw * Rate_Error_Max_Raw > 2**62,
      "Worst-case gain times error overflows the wide product type");

end Fsac.Types;