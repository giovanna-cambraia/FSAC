--  ===========================================================================
--  FSAC - Flight Stability Augmentation Computer
--  ===========================================================================
--  File        : software/platform_bridge/fsac-platform_ports.ads
--  Package     : Fsac.Platform_Ports  (specification; body in the .adb)
--  Language    : Ada 2012 / SPARK 2014
--  Assurance   : DO-178C Software Level A (target), DO-333 formal supplement
--  SPARK_Mode  : On
--  Requirements: HLR-HSI-0001, HLR-HSI-0013, HLR-BRG-0001 .. HLR-BRG-0006
--                (placeholder IDs)
--  Partner     : software/hal_c/include/fsac_hsi_sensor.h
--
--  PURPOSE
--    The one place where the C world (the sensor driver) meets the typed
--    Ada world (the SPARK core). The C driver leaves a 12-byte sample in
--    memory. This package describes that sample byte for byte, and turns it
--    into a Body_Rate that the core can use, or into a rejection.
--
--  WHY THIS PACKAGE IS NOT INSIDE src/
--    It is the single point of contact between the two languages, so it
--    lives in its own folder (software/platform_bridge/) and anyone who
--    changes it knows both sides are affected. The core packages under
--    src/ never see a C type.
--
--  TWO DEFENCES, NOT ONE
--    The C driver already checks plausibility range, CRC, flags, sequence
--    and step. This bridge checks again what the Ada core is about to
--    trust:
--      1. Is the sample internally consistent? (Does it obey the driver's
--         own output rules? If not, the sample was corrupted in memory or
--         the two sides disagree on the layout.)
--      2. Does the value fit the Body_Rate type? (This is the premise
--         stated in proof/README.md, section 6, item 3.)
--    Defence in depth is deliberate: the proof of the core is only as good
--    as its inputs, and this is where the inputs are made safe.
--
--  DECISION TABLE (Classify, first match wins)
--    1  Reserved /= 0, or Valid not in {0, 1}   Inconsistent_Sample
--    2  Valid = 0 and Value /= 0                Inconsistent_Sample
--                                               (rule R7 of the driver:
--                                                an invalid sample has value 0)
--    3  Valid = 0                               Driver_Invalid
--                                               (the normal "sensor not good")
--    4  Valid = 1 and Status /= OK              Inconsistent_Sample
--    5  Value outside Body_Rate                 Out_Of_Range
--    6  otherwise                               Accepted
--
--  WHAT IS PROVED (GNATprove)
--    * To_Rate_Reading returns exactly the reason given by Classify.
--    * Valid = (Reason = Accepted).
--    * When not Valid, Value = 0 (a rejected sample never carries a number).
--    * When Valid, the Body_Rate equals the C value (no change, no loss).
--    * The conversion never overflows or leaves the Body_Rate range.
--
--  LAYOUT CONTRACT WITH C (checked three ways)
--    1  Convention C plus an explicit representation clause here: every
--       component has a byte offset and the record size is 96 bits.
--    2  The C header has _Static_assert on sizeof and the C tests check
--       every offsetof (tests L-01 .. L-13).
--    3  A mixed-language test (tests/test_bridge.adb) asks the C side to
--       fill a sample and checks the Ada view field by field.
--    If any of the three disagrees, the build or a test fails.
--
--  NOTE ON THE FILE NAME
--    The plan in Part 1 called this file "fsac_platform_ports.ads". GNAT's
--    default naming needs the package Fsac.Platform_Ports to live in
--    fsac-platform_ports.ads, so the name was corrected here.

with Interfaces;
with Fsac.Types; use Fsac.Types;

package Fsac.Platform_Ports
  with SPARK_Mode => On
is

   --  makes the comparison operators of the C-sized types visible here
   use type Interfaces.Integer_32;
   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_16;

   --  status codes of the C driver (must equal FSAC_SENSOR_* in the header)
   subtype C_Status is Interfaces.Unsigned_8;

   Status_OK         : constant C_Status := 0;
   Status_Err_Null   : constant C_Status := 1;
   Status_Err_Config : constant C_Status := 2;
   Status_Err_Torn   : constant C_Status := 3;
   Status_Err_CRC    : constant C_Status := 4;
   Status_Err_HW     : constant C_Status := 5;
   Status_Err_Stale  : constant C_Status := 6;
   Status_Err_Seq    : constant C_Status := 7;
   Status_Err_Range  : constant C_Status := 8;
   Status_Err_Step   : constant C_Status := 9;

   --  the sample the C driver publishes (fsac_sensor_sample_t, 12 bytes)
   type Sensor_Sample is record
      Value    : Interfaces.Integer_32;   --  Q16 engineering value, or 0
      Frame    : Interfaces.Unsigned_32;  --  minor-frame number of the read
      Status   : Interfaces.Unsigned_8;   --  Status_OK or an error code
      Valid    : Interfaces.Unsigned_8;   --  1 valid, 0 invalid
      Reserved : Interfaces.Unsigned_16;  --  always 0
   end record
     with Convention => C;

   for Sensor_Sample use record
      Value    at 0  range 0 .. 31;
      Frame    at 4  range 0 .. 31;
      Status   at 8  range 0 .. 7;
      Valid    at 9  range 0 .. 7;
      Reserved at 10 range 0 .. 15;
   end record;

   for Sensor_Sample'Size use 96;

   --  what the core receives
   type Reject_Reason is
     (Accepted,
      Driver_Invalid,
      Inconsistent_Sample,
      Out_Of_Range);

   type Rate_Reading is record
      Value         : Body_Rate;   --  0 unless Valid
      Valid         : Boolean;
      Reason        : Reject_Reason;
      Driver_Status : C_Status;    --  copied from the sample, for the log
   end record;

   --  decision table (the specification of the conversion)
   function Classify (S : Sensor_Sample) return Reject_Reason is
     (if S.Reserved /= 0 or else S.Valid > 1 then
        Inconsistent_Sample
      elsif S.Valid = 0 then
        (if S.Value /= 0 then Inconsistent_Sample else Driver_Invalid)
      elsif S.Status /= Status_OK then
        Inconsistent_Sample
      elsif S.Value < Interfaces.Integer_32 (Body_Rate'First)
        or else S.Value > Interfaces.Integer_32 (Body_Rate'Last)
      then
        Out_Of_Range
      else
        Accepted)
     with Global => null;

   --  conversion for a rate measurement (Body_Rate, rad/s)
   function To_Rate_Reading (S : Sensor_Sample) return Rate_Reading
     with
       Global => null,
       Post   =>
         To_Rate_Reading'Result.Reason = Classify (S)
         and then To_Rate_Reading'Result.Valid =
                    (To_Rate_Reading'Result.Reason = Accepted)
         and then To_Rate_Reading'Result.Driver_Status = S.Status
         and then
           (if not To_Rate_Reading'Result.Valid then
              To_Rate_Reading'Result.Value = 0)
         and then
           (if To_Rate_Reading'Result.Valid then
              Interfaces.Integer_32 (To_Rate_Reading'Result.Value) = S.Value);

end Fsac.Platform_Ports;