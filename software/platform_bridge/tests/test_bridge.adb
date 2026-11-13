--  ===========================================================================
--  FSAC - Flight Stability Augmentation Computer
--  ===========================================================================
--  File        : software/platform_bridge/tests/test_bridge.adb
--  Unit        : Test_Bridge (main program, host only)
--  Purpose     : Mixed-language tests of Fsac.Platform_Ports against the C
--                sensor driver (DO-178C 6.4)
--  Requirements: HLR-HSI-0001, HLR-HSI-0013, HLR-BRG-0001 .. HLR-BRG-0006
--
--  WHAT THESE TESTS ADD
--    The proof of Fsac.Platform_Ports shows the conversion is right for any
--    Sensor_Sample. It cannot show that the Ada record and the C struct are
--    the SAME BYTES. These tests do, by asking the C compiler:
--      B-01  sizeof, alignment and every offset agree between Ada and C
--      B-02  a sample filled in C is read field by field in Ada
--      B-03  the decision table of Classify, row by row, with the edges
--      B-04  end to end: fake mailbox -> real C driver -> Ada bridge
--
--  HOW TO BUILD AND RUN (from software/platform_bridge/tests/)
--      gprbuild -P fsac_bridge_tests.gpr
--      ./test_bridge

with Ada.Text_IO;       use Ada.Text_IO;
with Ada.Command_Line;
with Interfaces;        use Interfaces;

with Fsac.Types;          use Fsac.Types;
with Fsac.Platform_Ports; use Fsac.Platform_Ports;

procedure Test_Bridge is

   Passed : Natural := 0;
   Failed : Natural := 0;

   procedure Check (Name : String; Condition : Boolean) is
   begin
      if Condition then
         Passed := Passed + 1;
      else
         Failed := Failed + 1;
         Put_Line ("FAIL  " & Name);
      end if;
   end Check;

   --  C side
   function C_Sizeof return Unsigned_32
     with Import, Convention => C, External_Name => "fsac_test_sizeof_sample";

   function C_Alignof return Unsigned_32
     with Import, Convention => C, External_Name => "fsac_test_alignof_sample";

   function C_Offset (Which : Unsigned_32) return Unsigned_32
     with Import, Convention => C, External_Name => "fsac_test_offset";

   procedure C_Fill
     (Item     : out Sensor_Sample;
      Value    : Integer_32;
      Frame    : Unsigned_32;
      Status   : Unsigned_8;
      Valid    : Unsigned_8;
      Reserved : Unsigned_16)
     with Import, Convention => C, External_Name => "fsac_test_fill";

   procedure C_Reset
     with Import, Convention => C, External_Name => "fsac_test_reset";

   procedure C_Pipeline
     (Counts : Integer_32;
      Flags  : Unsigned_16;
      Seq    : Unsigned_32;
      Item   : out Sensor_Sample)
     with Import, Convention => C, External_Name => "fsac_test_pipeline";

   --  B-01 layout
   procedure Test_Layout is
      Probe : constant Sensor_Sample := (0, 0, 0, 0, 0);
   begin
      Check ("B-01a size is 96 bits", Sensor_Sample'Size = 96);
      Check ("B-01b alignment is 4", Sensor_Sample'Alignment = 4);
      Check ("B-01c C sizeof is 12", C_Sizeof = 12);
      Check ("B-01d C alignment is 4", C_Alignof = 4);

      Check ("B-01e Value offset", Unsigned_32 (Probe.Value'Position) = C_Offset (0));
      Check ("B-01f Frame offset", Unsigned_32 (Probe.Frame'Position) = C_Offset (1));
      Check ("B-01g Status offset", Unsigned_32 (Probe.Status'Position) = C_Offset (2));
      Check ("B-01h Valid offset", Unsigned_32 (Probe.Valid'Position) = C_Offset (3));
      Check ("B-01i Reserved offset", Unsigned_32 (Probe.Reserved'Position) = C_Offset (4));

      Check ("B-01j expected offsets 0 4 8 9 10",
             C_Offset (0) = 0 and then C_Offset (1) = 4 and then C_Offset (2) = 8
             and then C_Offset (3) = 9 and then C_Offset (4) = 10);
   end Test_Layout;

   --  B-02 a sample filled in C, read in Ada
   procedure Test_Exchange is
      S : Sensor_Sample;
   begin
      C_Fill (S, -123_456, 16#DEAD_BEEF#, 7, 1, 16#BEEF#);
      Check ("B-02a Value", S.Value = -123_456);
      Check ("B-02b Frame", S.Frame = 16#DEAD_BEEF#);
      Check ("B-02c Status", S.Status = 7);
      Check ("B-02d Valid", S.Valid = 1);
      Check ("B-02e Reserved", S.Reserved = 16#BEEF#);

      C_Fill (S, Integer_32'First, 0, 255, 0, 0);
      Check ("B-02f extreme Value", S.Value = Integer_32'First);
      Check ("B-02g extreme Status", S.Status = 255);
   end Test_Exchange;

   --  B-03 decision table
   procedure Test_Classify is
      R : Rate_Reading;

      function Sample
        (Value : Integer_32; Status : Unsigned_8; Valid : Unsigned_8;
         Reserved : Unsigned_16 := 0) return Sensor_Sample
      is ((Value => Value, Frame => 1, Status => Status, Valid => Valid,
           Reserved => Reserved));
   begin
      --  row 6: accepted, with the edges of the Body_Rate range (+-8.0 rad/s)
      R := To_Rate_Reading (Sample (1_000, Status_OK, 1));
      Check ("B-03a accepted", R.Valid and then R.Reason = Accepted
             and then R.Value = 1_000 and then R.Driver_Status = Status_OK);

      R := To_Rate_Reading (Sample (524_288, Status_OK, 1));
      Check ("B-03b upper edge accepted", R.Valid and then R.Value = 524_288);

      R := To_Rate_Reading (Sample (-524_288, Status_OK, 1));
      Check ("B-03c lower edge accepted", R.Valid and then R.Value = -524_288);

      R := To_Rate_Reading (Sample (0, Status_OK, 1));
      Check ("B-03d zero accepted", R.Valid and then R.Value = 0);

      --  row 5: out of range, one step beyond each edge and at the extremes
      R := To_Rate_Reading (Sample (524_289, Status_OK, 1));
      Check ("B-03e one above the edge", (not R.Valid) and then R.Reason = Out_Of_Range
             and then R.Value = 0);

      R := To_Rate_Reading (Sample (-524_289, Status_OK, 1));
      Check ("B-03f one below the edge", (not R.Valid) and then R.Reason = Out_Of_Range
             and then R.Value = 0);

      R := To_Rate_Reading (Sample (Integer_32'First, Status_OK, 1));
      Check ("B-03g Integer_32'First (not representable in Q16)",
             (not R.Valid) and then R.Reason = Out_Of_Range and then R.Value = 0);

      R := To_Rate_Reading (Sample (Integer_32'Last, Status_OK, 1));
      Check ("B-03h Integer_32'Last", (not R.Valid) and then R.Reason = Out_Of_Range);

      --  row 3: the normal invalid sample, the driver's code is passed on
      R := To_Rate_Reading (Sample (0, Status_Err_HW, 0));
      Check ("B-03i driver invalid", (not R.Valid) and then R.Reason = Driver_Invalid
             and then R.Value = 0 and then R.Driver_Status = Status_Err_HW);

      --  row 2: an invalid sample must carry value 0 (driver rule R7)
      R := To_Rate_Reading (Sample (5, Status_Err_HW, 0));
      Check ("B-03j invalid with a nonzero value", R.Reason = Inconsistent_Sample
             and then not R.Valid and then R.Value = 0);

      --  row 4: valid flag set but status is an error
      R := To_Rate_Reading (Sample (1_000, Status_Err_CRC, 1));
      Check ("B-03k valid flag with error status", R.Reason = Inconsistent_Sample
             and then not R.Valid);

      --  row 1: reserved not zero, valid not 0 or 1
      R := To_Rate_Reading (Sample (1_000, Status_OK, 1, 1));
      Check ("B-03l reserved not zero", R.Reason = Inconsistent_Sample and then not R.Valid);

      R := To_Rate_Reading (Sample (1_000, Status_OK, 2));
      Check ("B-03m valid flag 2", R.Reason = Inconsistent_Sample and then not R.Valid);

      R := To_Rate_Reading (Sample (1_000, Status_OK, 255));
      Check ("B-03n valid flag 255", R.Reason = Inconsistent_Sample and then not R.Valid);

      --  priority: row 1 beats row 3
      R := To_Rate_Reading (Sample (0, Status_Err_HW, 0, 9));
      Check ("B-03o reserved is checked before valid = 0",
             R.Reason = Inconsistent_Sample);

      --  priority: row 2 beats row 5
      R := To_Rate_Reading (Sample (Integer_32'Last, Status_Err_HW, 0));
      Check ("B-03p invalid with value beats out of range",
             R.Reason = Inconsistent_Sample);
   end Test_Classify;

   --  B-04 end to end through the real C driver
   --  the C helper configures the driver with the widest legal range, so the driver itself accepts values above 8 rad/s; the Ada bridge must be the one that stops them

   procedure Test_End_To_End is
      S : Sensor_Sample;
      R : Rate_Reading;
   begin
      C_Reset;

      C_Pipeline (1_000, 0, 1, S);
      R := To_Rate_Reading (S);
      Check ("B-04a nominal sample reaches the core",
             R.Valid and then R.Value = 1_000 and then S.Frame = 1);

      C_Pipeline (2_000, 16#0001#, 2, S);
      R := To_Rate_Reading (S);
      Check ("B-04b hardware flag: driver rejects",
             (not R.Valid) and then R.Reason = Driver_Invalid
             and then R.Driver_Status = Status_Err_HW and then R.Value = 0);

      C_Pipeline (600_000, 0, 3, S);
      Check ("B-04c the driver accepted 600000 (about 9.2 rad/s)",
             S.Valid = 1 and then S.Value = 600_000);
      R := To_Rate_Reading (S);
      Check ("B-04d the bridge rejects it: Out_Of_Range, status stays OK",
             (not R.Valid) and then R.Reason = Out_Of_Range
             and then R.Value = 0 and then R.Driver_Status = Status_OK);

      C_Pipeline (-1_000, 0, 4, S);
      R := To_Rate_Reading (S);
      Check ("B-04e negative sample reaches the core",
             R.Valid and then R.Value = -1_000);

      C_Pipeline (-1_000, 16#8000#, 5, S);
      R := To_Rate_Reading (S);
      Check ("B-04f unknown flag bit is a fault end to end (ADR-007)",
             (not R.Valid) and then R.Reason = Driver_Invalid
             and then R.Driver_Status = Status_Err_HW);
   end Test_End_To_End;

begin
   Put_Line ("FSAC bridge tests");

   Test_Layout;
   Test_Exchange;
   Test_Classify;
   Test_End_To_End;

   New_Line;
   Put_Line ("passed:" & Natural'Image (Passed));
   Put_Line ("failed:" & Natural'Image (Failed));

   if Failed > 0 then
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   end if;
end Test_Bridge;