--  ===========================================================================
--  FSAC - Flight Stability Augmentation Computer
--  ===========================================================================
--  File        : software/core_spark/tests/test_signal_mgmt.adb
--  Unit        : Test_Signal_Mgmt (main program, host only)
--  Language    : Ada 2012
--  Purpose     : Requirements-based tests of Part 4: Mid_Value_Select,
--                Cross_Check, Observer, Voter and Modes, plus an integration
--                fault campaign through Voter -> Modes -> Pitch_Rate_Damper
--  Requirements: HLR-SIG-0005 .. HLR-SIG-0048, HLR-MOD-0001 .. HLR-MOD-0016
--
--  WHAT THESE TESTS ARE FOR
--    The proofs show that each unit keeps its contracts for every input. These
--    tests check the BEHAVIOUR that the requirements describe, in sequences:
--    a sensor that fails and is excluded, a reference that expires, a mode
--    that never improves. They also check properties the contracts cannot
--    express (for example that a failed sensor's garbage has no influence).
--
--  TEST GROUPS
--    MV  Mid_Value_Select        HLR-SIG-0005 .. 0012
--    XC  Cross_Check             HLR-SIG-0013 .. 0024
--    OB  Observer                HLR-SIG-0025 .. 0034
--    VT  Voter                   HLR-SIG-0035 .. 0048
--    MD  Modes                   HLR-MOD-0001 .. 0016
--    IT  integration campaign    HLR-SIG-0035, HLR-MOD-0001, HLR-CTL-0020
--
--  HOW EXPECTED VALUES WERE OBTAINED
--    By hand from the algorithms in the specifications, with the arithmetic
--    written next to the test when it is not obvious. As in test_core.adb,
--    hand derivation is a first baseline; an independent model is the next
--    step before any certification credit.
--
--  RANDOMIZED TESTS
--    XC-13, OB-12 and MD-12 use a deterministic generator with a fixed seed,
--    so they are repeatable. They check invariants on thousands of frames of
--    arbitrary input, which complements the proofs with an execution check.
--
--  HOW TO BUILD AND RUN (from software/core_spark/tests/)
--    gnatmake -gnat2012 -gnata -gnato -o test_signal_mgmt test_signal_mgmt.adb \
--      -I../src -I../src/types -I../src/math -I../src/params \
--      -I../src/control -I../src/signal_mgmt -I../src/modes
--    ./test_signal_mgmt
--
--    -gnata is required: it makes the compiler evaluate predicates, so the
--    coupling rule of Voter_Params is checked at run time (test VT-13).

with Ada.Text_IO;      use Ada.Text_IO;
with Ada.Command_Line;
with Ada.Assertions;
with Interfaces;       use Interfaces;

with Fsac.Types;                    use Fsac.Types;
with Fsac.Control;
with Fsac.Control.Params;
with Fsac.Control.Pitch_Rate_Damper;
with Fsac.Signal_Mgmt;              use Fsac.Signal_Mgmt;
with Fsac.Signal_Mgmt.Mid_Value_Select;
with Fsac.Signal_Mgmt.Cross_Check;
with Fsac.Signal_Mgmt.Observer;
with Fsac.Signal_Mgmt.Voter;
with Fsac.Modes;

procedure Test_Signal_Mgmt is

   package MVS renames Fsac.Signal_Mgmt.Mid_Value_Select;
   package CC  renames Fsac.Signal_Mgmt.Cross_Check;
   package OBS renames Fsac.Signal_Mgmt.Observer;
   package VT  renames Fsac.Signal_Mgmt.Voter;
   package MD  renames Fsac.Modes;
   package DMP renames Fsac.Control.Pitch_Rate_Damper;
   package CTL renames Fsac.Control;

   use type CC.Decision;
   use type CC.Check_State;
   use type MD.Mode;
   use type MD.Mode_State;
   use type MVS.Vote_Result;
   use type CTL.Loop_Status;

   Passed       : Natural := 0;
   Failures     : Natural := 0;
   --  (not named "Failed": that is a literal of Sensor_Health)

   procedure Check (Name : String; Condition : Boolean) is
   begin
      if Condition then
         Passed := Passed + 1;
      else
         Failures := Failures + 1;
         Put_Line ("FAIL  " & Name);
      end if;
   end Check;

   --  A set of three readings (all valid unless told otherwise).
   function Rd
     (A, B, C : Body_Rate;
      VA : Boolean := True;
      VB : Boolean := True;
      VC : Boolean := True) return Reading_Set
   is ((A, VA), (B, VB), (C, VC));

   All_Healthy : constant Health_Set := (others => Healthy);

   No_Ref : constant CC.Reference := (Value => 0, Valid => False);

   --  Deterministic pseudo-random numbers (fixed seed, repeatable)

   Seed : Unsigned_32 := 12_345;

   function Next_Random return Unsigned_32 is
   begin
      Seed := Seed * 1_664_525 + 1_013_904_223;   --  modular arithmetic
      return Shift_Right (Seed, 8);
   end Next_Random;

   function Random_Rate return Body_Rate is
   begin
      return Body_Rate (Integer (Next_Random mod 1_048_577) - 524_288);
   end Random_Rate;

   function Random_Below (N : Positive) return Natural is
   begin
      return Natural (Next_Random mod Unsigned_32 (N));
   end Random_Below;

   --  MV: Mid_Value_Select

   procedure Test_MVS is
      V : MVS.Vote_Result;
      Garbage : constant array (1 .. 5) of Body_Rate :=
        (Body_Rate'First, -1, 0, 7_777, Body_Rate'Last);
   begin
      --  MV-01 the six orderings of three distinct values
      Check ("MV-01a 10 20 30", MVS.Median3 (10, 20, 30) = 20);
      Check ("MV-01b 10 30 20", MVS.Median3 (10, 30, 20) = 20);
      Check ("MV-01c 20 10 30", MVS.Median3 (20, 10, 30) = 20);
      Check ("MV-01d 20 30 10", MVS.Median3 (20, 30, 10) = 20);
      Check ("MV-01e 30 10 20", MVS.Median3 (30, 10, 20) = 20);
      Check ("MV-01f 30 20 10", MVS.Median3 (30, 20, 10) = 20);

      --  MV-02 ties and signs
      Check ("MV-02a two low equal", MVS.Median3 (5, 5, 9) = 5);
      Check ("MV-02b two high equal", MVS.Median3 (5, 9, 9) = 9);
      Check ("MV-02c all equal", MVS.Median3 (7, 7, 7) = 7);
      Check ("MV-02d negatives", MVS.Median3 (-5, -10, 3) = -5);

      --  MV-03 extremes of the Body_Rate range
      Check ("MV-03a first 0 last", MVS.Median3 (Body_Rate'First, 0, Body_Rate'Last) = 0);
      Check ("MV-03b last last first",
             MVS.Median3 (Body_Rate'Last, Body_Rate'Last, Body_Rate'First) = Body_Rate'Last);
      Check ("MV-03c first first last",
             MVS.Median3 (Body_Rate'First, Body_Rate'First, Body_Rate'Last) = Body_Rate'First);

      --  MV-04 midpoint: truncation toward zero, symmetric, no overflow
      Check ("MV-04a 10 20", MVS.Midpoint (10, 20) = 15);
      Check ("MV-04b 10 11 truncates down", MVS.Midpoint (10, 11) = 10);
      Check ("MV-04c -10 -11 truncates toward zero", MVS.Midpoint (-10, -11) = -10);
      Check ("MV-04d -3 4", MVS.Midpoint (-3, 4) = 0);
      Check ("MV-04e last last", MVS.Midpoint (Body_Rate'Last, Body_Rate'Last) = Body_Rate'Last);
      Check ("MV-04f first last", MVS.Midpoint (Body_Rate'First, Body_Rate'Last) = 0);
      Check ("MV-04g last and last-1",
             MVS.Midpoint (Body_Rate'Last, Body_Rate'Last - 1) = Body_Rate'Last - 1);
      Check ("MV-04h first and first+1",
             MVS.Midpoint (Body_Rate'First, Body_Rate'First + 1) = Body_Rate'First + 1);
      declare
         Symmetric : Boolean := True;
      begin
         for A in -4 .. 4 loop
            for B in -4 .. 4 loop
               if MVS.Midpoint (Body_Rate (A * 1000 + 3), Body_Rate (B * 1000 - 7))
                 /= MVS.Midpoint (Body_Rate (B * 1000 - 7), Body_Rate (A * 1000 + 3))
               then
                  Symmetric := False;
               end if;
            end loop;
         end loop;
         Check ("MV-04i midpoint is symmetric", Symmetric);
      end;

      --  MV-05 levels and values
      V := MVS.Vote (Rd (100, 200, 300), All_Healthy);
      Check ("MV-05a triplex", V.Value = 200 and then V.Count = 3 and then V.Level = Triplex);

      V := MVS.Vote (Rd (999, 200, 300, VA => False), All_Healthy);
      Check ("MV-05b duplex without 1", V.Value = 250 and then V.Count = 2 and then V.Level = Duplex);
      V := MVS.Vote (Rd (100, 999, 300, VB => False), All_Healthy);
      Check ("MV-05c duplex without 2", V.Value = 200 and then V.Level = Duplex);
      V := MVS.Vote (Rd (100, 200, 999, VC => False), All_Healthy);
      Check ("MV-05d duplex without 3", V.Value = 150 and then V.Level = Duplex);

      V := MVS.Vote (Rd (100, 9, 9, VB => False, VC => False), All_Healthy);
      Check ("MV-05e simplex 1", V.Value = 100 and then V.Level = Simplex);
      V := MVS.Vote (Rd (9, 200, 9, VA => False, VC => False), All_Healthy);
      Check ("MV-05f simplex 2", V.Value = 200 and then V.Level = Simplex);
      V := MVS.Vote (Rd (9, 9, 300, VA => False, VB => False), All_Healthy);
      Check ("MV-05g simplex 3", V.Value = 300 and then V.Level = Simplex);

      V := MVS.Vote (Rd (1, 2, 3, False, False, False), All_Healthy);
      Check ("MV-05h lost", V.Value = 0 and then V.Count = 0 and then V.Level = Lost);

      --  MV-06 a Failed sensor is excluded exactly like an invalid one
      V := MVS.Vote (Rd (999, 200, 300), (Failed, Healthy, Healthy));
      Check ("MV-06a failed 1", V.Value = 250 and then V.Level = Duplex);
      V := MVS.Vote (Rd (999, 888, 300), (Failed, Healthy, Healthy));
      Check ("MV-06b failed 1, invalid 2 handled by health only",
             V.Level = Duplex);   --  sensor 2 is valid and Healthy here
      V := MVS.Vote (Rd (999, 888, 300, VB => False), (Failed, Healthy, Healthy));
      Check ("MV-06c failed 1 and invalid 2", V.Value = 300 and then V.Level = Simplex);

      --  MV-07 Suspect is still used
      V := MVS.Vote (Rd (100, 200, 300), (Suspect, Healthy, Suspect));
      Check ("MV-07 suspect sensors still vote", V.Value = 200 and then V.Level = Triplex);

      --  MV-08 the leak test (property M6): the value of a sensor that is NOT
      --  usable never changes the result, wherever it sits and whatever the
      --  cause (invalid reading or Failed health)
      declare
         Leak_Free : Boolean := True;
      begin
         for Pos in Sensor_Id loop
            for Cause in 1 .. 2 loop
               declare
                  Base_R : Reading_Set := Rd (100, 200, 300);
                  H      : Health_Set := All_Healthy;
                  Baseline : MVS.Vote_Result;
               begin
                  if Cause = 2 then
                     H (Pos) := Failed;
                  end if;

                  Base_R (Pos) := (Value => 0, Valid => Cause = 2);
                  Baseline := MVS.Vote (Base_R, H);

                  for G in Garbage'Range loop
                     declare
                        R : Reading_Set := Base_R;
                     begin
                        R (Pos).Value := Garbage (G);
                        if MVS.Vote (R, H) /= Baseline then
                           Leak_Free := False;
                        end if;
                     end;
                  end loop;
               end;
            end loop;
         end loop;
         Check ("MV-08 an unusable sensor has no influence", Leak_Free);
      end;

      --  MV-09 exhaustive grid: for every pair of usable sensors the result
      --  lies between them; with three, it is one of the readings
      declare
         Grid : constant array (1 .. 7) of Body_Rate :=
           (Body_Rate'First, -1_000, -1, 0, 1, 1_000, Body_Rate'Last);
         Grid_OK : Boolean := True;
         Cases   : Natural := 0;
      begin
         for A in Grid'Range loop
            for B in Grid'Range loop
               for C in Grid'Range loop
                  for Mask in 0 .. 7 loop
                     declare
                        R : constant Reading_Set :=
                          Rd (Grid (A), Grid (B), Grid (C),
                              VA => Mask mod 2 = 1,
                              VB => (Mask / 2) mod 2 = 1,
                              VC => Mask / 4 = 1);
                        W : constant MVS.Vote_Result := MVS.Vote (R, All_Healthy);
                     begin
                        Cases := Cases + 1;
                        for I in Sensor_Id loop
                           for J in Sensor_Id loop
                              if I < J and then R (I).Valid and then R (J).Valid then
                                 if not MVS.Within (W.Value, R (I).Value, R (J).Value) then
                                    Grid_OK := False;
                                 end if;
                              end if;
                           end loop;
                        end loop;
                        if W.Count = 3
                          and then W.Value /= R (1).Value
                          and then W.Value /= R (2).Value
                          and then W.Value /= R (3).Value
                        then
                           Grid_OK := False;
                        end if;
                     end;
                  end loop;
               end loop;
            end loop;
         end loop;
         Check ("MV-09 exhaustive grid of" & Natural'Image (Cases) & " cases", Grid_OK);
      end;
   end Test_MVS;

   --  XC: Cross_Check

   P_CC : constant CC.Check_Params :=
     (Threshold => CC.Default_Threshold, Persistence => CC.Default_Persistence);
   --  Threshold 6_554 (0.10 rad/s), persistence 8 frames.

   procedure Test_Cross_Check is
      S : CC.Check_State := CC.Initial_State;
      Rep : CC.Check_Report;
   begin
      --  XC-01 initial state
      Check ("XC-01a initial state consistent", CC.Consistent (CC.Initial_State, P_CC));
      Check ("XC-01b initial health all Healthy", CC.Health_Of (CC.Initial_State) = All_Healthy);

      --  XC-02 everybody agrees
      CC.Update (S, P_CC, Rd (1000, 1010, 1005), No_Ref, Rep);
      Check ("XC-02 all agree, nothing changes",
             Rep.Result = CC.All_Agree and then S = CC.Initial_State
             and then not Rep.Newly_Failed);

      --  XC-03 the boundary of the threshold (6_554)
      S := CC.Initial_State;
      CC.Update (S, P_CC, Rd (0, 6_554, 0), No_Ref, Rep);
      Check ("XC-03a difference of exactly the threshold agrees",
             Rep.Result = CC.All_Agree);
      CC.Update (S, P_CC, Rd (0, 6_555, 0), No_Ref, Rep);
      Check ("XC-03b one above the threshold: the odd sensor is located",
             Rep.Result = CC.Located and then Rep.Outlier = 2);

      --  XC-04 a hard-over on each position, both directions
      for Pos in Sensor_Id loop
         for Sign in 1 .. 2 loop
            declare
               Bad  : constant Body_Rate := (if Sign = 1 then 40_000 else -40_000);
               R    : Reading_Set := Rd (1000, 1010, 1005);
               Ok_Steps : Boolean := True;
            begin
               S := CC.Initial_State;
               R (Pos).Value := Bad;

               for K in 1 .. 7 loop
                  CC.Update (S, P_CC, R, No_Ref, Rep);
                  if not (Rep.Result = CC.Located and then Rep.Outlier = Pos
                          and then S (Pos).Health = Suspect and then S (Pos).Count = K
                          and then not Rep.Newly_Failed)
                  then
                     Ok_Steps := False;
                  end if;
               end loop;
               Check ("XC-04a suspect for 7 frames, sensor" & Pos'Image
                      & " sign" & Sign'Image, Ok_Steps);

               CC.Update (S, P_CC, R, No_Ref, Rep);
               Check ("XC-04b failed at the 8th frame, sensor" & Pos'Image
                      & " sign" & Sign'Image,
                      S (Pos).Health = Failed and then S (Pos).Count = 8
                      and then Rep.Newly_Failed);

               CC.Update (S, P_CC, R, No_Ref, Rep);
               Check ("XC-04c afterwards the other two agree, nothing newly failed",
                      Rep.Result = CC.All_Agree and then not Rep.Newly_Failed
                      and then S (Pos).Health = Failed);
            end;
         end loop;
      end loop;

      --  XC-05 two usable sensors that disagree
      --      (sensor 3 invalid; values 1000 and 20000)
      S := CC.Initial_State;
      CC.Update (S, P_CC, Rd (1000, 20_000, 0, VC => False),
                 (Value => 1_010, Valid => True), Rep);
      Check ("XC-05a located by a reference close to one of them",
             Rep.Result = CC.Located and then Rep.Outlier = 2 and then S (2).Count = 1);

      S := CC.Initial_State;
      CC.Update (S, P_CC, Rd (1000, 20_000, 0, VC => False),
                 (Value => 20_050, Valid => True), Rep);
      Check ("XC-05b the reference may point at either sensor",
             Rep.Result = CC.Located and then Rep.Outlier = 1);

      S := CC.Initial_State;
      CC.Update (S, P_CC, Rd (1000, 20_000, 0, VC => False), No_Ref, Rep);
      Check ("XC-05c no reference: unresolved, state unchanged",
             Rep.Result = CC.Unresolved and then S = CC.Initial_State);

      CC.Update (S, P_CC, Rd (1000, 20_000, 0, VC => False),
                 (Value => 10_000, Valid => True), Rep);
      Check ("XC-05d reference far from both: unresolved",
             Rep.Result = CC.Unresolved and then S = CC.Initial_State);

      CC.Update (S, P_CC, Rd (1000, 8_000, 0, VC => False),
                 (Value => 4_500, Valid => True), Rep);
      Check ("XC-05e reference close to both: unresolved",
             Rep.Result = CC.Unresolved and then S = CC.Initial_State);

      CC.Update (S, P_CC, Rd (1000, 1_010, 0, VC => False),
                 (Value => 50_000, Valid => True), Rep);
      Check ("XC-05f the pair agrees: the reference is ignored",
             Rep.Result = CC.All_Agree and then S = CC.Initial_State);

      --  XC-06 three usable, no sensor can be blamed
      S := CC.Initial_State;
      CC.Update (S, P_CC, Rd (0, 6_000, 12_000), No_Ref, Rep);
      Check ("XC-06a chain 1~2~3: unresolved, unchanged",
             Rep.Result = CC.Unresolved and then S = CC.Initial_State);
      CC.Update (S, P_CC, Rd (0, 20_000, 40_000), No_Ref, Rep);
      Check ("XC-06b nobody agrees: unresolved, unchanged",
             Rep.Result = CC.Unresolved and then S = CC.Initial_State);

      --  XC-07 an invalid reading takes no part, whatever its value
      S := CC.Initial_State;
      CC.Update (S, P_CC, Rd (1000, 1_010, 50_000, VC => False), No_Ref, Rep);
      Check ("XC-07 invalid reading is ignored",
             Rep.Result = CC.All_Agree and then S (3).Count = 0);

      --  XC-08 fewer than two usable: no comparison, state kept (even a
      --  partly filled counter)
      S := CC.Initial_State;
      CC.Update (S, P_CC, Rd (1000, 1_010, 50_000), No_Ref, Rep);   --  sensor 3 suspect
      declare
         Before : constant CC.Check_State := S;
      begin
         CC.Update (S, P_CC, Rd (1000, 0, 0, VB => False, VC => False), No_Ref, Rep);
         Check ("XC-08a one usable: insufficient, state kept",
                Rep.Result = CC.Insufficient and then S = Before);
         CC.Update (S, P_CC, Rd (1, 2, 3, False, False, False), No_Ref, Rep);
         Check ("XC-08b none usable: insufficient, state kept",
                Rep.Result = CC.Insufficient and then S = Before);
      end;

      --  XC-09 the leaky bucket
      S := CC.Initial_State;
      declare
         N : Natural := 0;
      begin
         while S (2).Health /= Failed and then N < 100 loop
            N := N + 1;
            if N mod 4 /= 0 then
               CC.Update (S, P_CC, Rd (1000, 30_000, 1005), No_Ref, Rep);
            else
               CC.Update (S, P_CC, Rd (1000, 1_002, 1005), No_Ref, Rep);
            end if;
         end loop;
         Check ("XC-09a a sensor wrong 3 frames out of 4 is caught", S (2).Health = Failed);
      end;

      S := CC.Initial_State;
      for K in 1 .. 60 loop
         if K mod 2 = 1 then
            CC.Update (S, P_CC, Rd (1000, 30_000, 1005), No_Ref, Rep);
         else
            CC.Update (S, P_CC, Rd (1000, 1_002, 1005), No_Ref, Rep);
         end if;
      end loop;
      Check ("XC-09b wrong exactly half of the time: NOT caught (documented limit)",
             S (2).Health /= Failed);

      S := CC.Initial_State;
      CC.Update (S, P_CC, Rd (1000, 30_000, 1005), No_Ref, Rep);
      CC.Update (S, P_CC, Rd (1000, 1_002, 1005), No_Ref, Rep);
      Check ("XC-09c a single glitch drains away",
             S (2).Health = Healthy and then S (2).Count = 0);

      S := CC.Initial_State;
      for K in 1 .. 2 loop
         CC.Update (S, P_CC, Rd (1000, 1_010, 50_000), No_Ref, Rep);
      end loop;
      for K in 1 .. 2 loop
         CC.Update (S, P_CC, Rd (1000, 1_010, 1_005), No_Ref, Rep);
      end loop;
      Check ("XC-09d a suspect that agrees again becomes Healthy",
             S (3).Health = Healthy and then S (3).Count = 0);

      --  XC-10 the persistence limits
      declare
         P1  : constant CC.Check_Params := (Threshold => 6_554, Persistence => 1);
         P24 : constant CC.Check_Params := (Threshold => 6_554, Persistence => 24);
         S1  : CC.Check_State := CC.Initial_State;
         S24 : CC.Check_State := CC.Initial_State;
      begin
         CC.Update (S1, P1, Rd (1000, 1_010, 50_000), No_Ref, Rep);
         Check ("XC-10a persistence 1 fails on the first located frame",
                S1 (3).Health = Failed and then Rep.Newly_Failed);

         for K in 1 .. 23 loop
            CC.Update (S24, P24, Rd (1000, 1_010, 50_000), No_Ref, Rep);
         end loop;
         Check ("XC-10b persistence 24: still suspect after 23 frames",
                S24 (3).Health = Suspect and then S24 (3).Count = 23);
         CC.Update (S24, P24, Rd (1000, 1_010, 50_000), No_Ref, Rep);
         Check ("XC-10c persistence 24: failed at frame 24",
                S24 (3).Health = Failed and then Rep.Newly_Failed);
      end;

      --  XC-11 a Failed sensor is latched and no longer compared
      S := CC.Initial_State;
      S (3) := (Health => Failed, Count => 8);
      CC.Update (S, P_CC, Rd (1000, 1_010, 50_000), No_Ref, Rep);
      Check ("XC-11a failed sensor out of the comparison: the pair agrees",
             Rep.Result = CC.All_Agree and then S (3).Health = Failed);
      CC.Update (S, P_CC, Rd (1000, 1_010, 1_005), No_Ref, Rep);
      Check ("XC-11b it does not return even when it agrees again",
             S (3).Health = Failed);

      --  XC-12 two faults at once cannot be separated by the sensors alone
      S := CC.Initial_State;
      CC.Update (S, P_CC, Rd (0, 20_000, 40_000), No_Ref, Rep);
      Check ("XC-12 double fault: unresolved, nobody blamed",
             Rep.Result = CC.Unresolved and then S = CC.Initial_State);

      --  XC-13 randomized: 3000 frames of arbitrary readings, validity and
      --  reference; the invariants must hold and Failed must never revert
      declare
         Rnd     : CC.Check_State := CC.Initial_State;
         Prev    : CC.Check_State;
         OK_Inv  : Boolean := True;
         OK_Latch : Boolean := True;
         R       : Reading_Set;
         Ref     : CC.Reference;
      begin
         for Frame in 1 .. 3_000 loop
            Prev := Rnd;
            for I in Sensor_Id loop
               R (I) := (Value => Random_Rate, Valid => Random_Below (10) /= 0);
               --  half of the frames: readings close to each other
               if Frame mod 2 = 0 then
                  R (I).Value := Body_Rate (500 + Random_Below (5_000));
               end if;
            end loop;
            Ref := (Value => Random_Rate, Valid => Random_Below (3) /= 0);

            CC.Update (Rnd, P_CC, R, Ref, Rep);

            if not CC.Consistent (Rnd, P_CC) then
               OK_Inv := False;
            end if;
            for I in Sensor_Id loop
               if Prev (I).Health = Failed and then Rnd (I).Health /= Failed then
                  OK_Latch := False;
               end if;
            end loop;
         end loop;
         Check ("XC-13a state stays consistent over 3000 random frames", OK_Inv);
         Check ("XC-13b Failed never reverts over 3000 random frames", OK_Latch);
      end;
   end Test_Cross_Check;

   --  OB: Observer

   procedure Test_Observer is
      P  : constant OBS.Observer_Params := OBS.Default_Params;
      S  : OBS.Observer_State := OBS.Initial_State;
   begin
      --  OB-01 starting point
      Check ("OB-01a starts without a valid reference", not OBS.Reference_Valid (S, P));
      Check ("OB-01b not initialized, age at its cap",
             (not S.Initialized) and then S.Age = OBS.Age_Frames'Last);

      --  OB-02 the first trusted measurement initializes it
      OBS.Update (S, P, 0, 0, True);
      Check ("OB-02 first trusted step initializes",
             S.Initialized and then S.Age = 0 and then S.Estimate = 0
             and then OBS.Reference_Valid (S, P));

      --  OB-03 dead reckoning: command 1.0 adds B (0.10 rad/s) in one frame
      OBS.Update (S, P, 65_536, 0, False);
      Check ("OB-03 command adds B, age grows",
             S.Estimate = 6_554 and then S.Age = 1 and then S.Initialized);

      --  OB-04 free response: A * 6554 = 66191 * 6554 / 65536 = 6619 (truncated)
      Check ("OB-04 free response A", OBS.Predict (S, P, 0) = 6_619);

      --  OB-05 steady-state bias (see the specification): m = 20000 settles
      --  at L * m / (1 - (1 - L) * A) = 20478, that is 1.024 * m
      S := OBS.Initial_State;
      for K in 1 .. 200 loop
         OBS.Update (S, P, 0, 20_000, True);
      end loop;
      Check ("OB-05 settles at the documented bias (about 1.024 x m)",
             S.Estimate > 20_300 and then S.Estimate < 20_700);

      --  OB-06 the validity window is exactly Max_Age frames
      for K in 1 .. 8 loop
         OBS.Update (S, P, 0, 0, False);
         Check ("OB-06a still valid after" & K'Image & " untrusted frames",
                OBS.Reference_Valid (S, P) and then S.Age = K);
      end loop;
      OBS.Update (S, P, 0, 0, False);
      Check ("OB-06b invalid after Max_Age + 1 untrusted frames",
             (not OBS.Reference_Valid (S, P)) and then S.Age = 9);

      --  OB-07 the age saturates; a trusted frame revives the reference
      for K in 1 .. 40 loop
         OBS.Update (S, P, 0, 0, False);
      end loop;
      Check ("OB-07a age saturates at 24", S.Age = OBS.Age_Frames'Last);
      Check ("OB-07b stays initialized but invalid",
             S.Initialized and then not OBS.Reference_Valid (S, P));
      OBS.Update (S, P, 0, 5_000, True);
      Check ("OB-07c a trusted frame revives it",
             OBS.Reference_Valid (S, P) and then S.Age = 0);

      --  OB-08 an unstable open loop is clamped to the Body_Rate range
      S := (Estimate => 500_000, Age => 0, Initialized => True);
      for K in 1 .. 50 loop
         OBS.Update (S, (A => 131_072, B => 0, L => 0, Max_Age => 8), 0, 0, False);
      end loop;
      Check ("OB-08 open-loop growth is clamped to +8 rad/s", S.Estimate = Body_Rate'Last);

      --  OB-09 correction gain 0: the measurement does not move the estimate
      S := OBS.Initial_State;
      OBS.Update (S, (A => 66_191, B => 6_554, L => 0, Max_Age => 8), 0, 5_000, True);
      Check ("OB-09 L = 0 ignores the measurement but still initializes",
             S.Estimate = 0 and then S.Initialized and then S.Age = 0);

      --  OB-10 correction gain 1: the estimate copies the measurement
      S := OBS.Initial_State;
      OBS.Update (S, (A => 66_191, B => 6_554, L => 65_536, Max_Age => 8), 0, 5_000, True);
      Check ("OB-10 L = 1 copies the measurement", S.Estimate = 5_000);

      --  OB-11 the form Cross_Check consumes
      S := (Estimate => 1_234, Age => 3, Initialized => True);
      Check ("OB-11a Reference_Of fresh",
             OBS.Reference_Of (S, P).Valid and then OBS.Reference_Of (S, P).Value = 1_234);
      S.Age := 9;
      Check ("OB-11b Reference_Of stale", not OBS.Reference_Of (S, P).Valid);

      --  OB-12 randomized: the correction never overshoots the measurement
      declare
         Pred_Before : Body_Rate;
         OK_Between  : Boolean := True;
         OK_Dead     : Boolean := True;
         Cmd         : Surface_Cmd;
         Meas        : Body_Rate;
         Trusted     : Boolean;
      begin
         for N in 1 .. 2_000 loop
            S := (Estimate    => Random_Rate,
                  Age         => Random_Below (25),
                  Initialized => Random_Below (2) = 1);
            Cmd := Surface_Cmd (Random_Below (131_073) - 65_536);
            Meas := Random_Rate;
            Trusted := Random_Below (2) = 1;
            Pred_Before := OBS.Predict (S, P, Cmd);

            OBS.Update (S, P, Cmd, Meas, Trusted);

            if Trusted then
               if not MVS.Within (S.Estimate, Pred_Before, Meas) then
                  OK_Between := False;
               end if;
            elsif S.Estimate /= Pred_Before then
               OK_Dead := False;
            end if;
         end loop;
         Check ("OB-12a trusted correction stays between prediction and measurement", OK_Between);
         Check ("OB-12b untrusted update is exactly the prediction", OK_Dead);
      end;
   end Test_Observer;

   --  VT: Voter

   function Accepts
     (Persistence : CC.Persistence_Frames;
      Max_Age     : OBS.Max_Age_Frames) return Boolean
   is
   begin
      declare
         Candidate : constant VT.Voter_Params :=
           (Check => (Threshold => 6_554, Persistence => Persistence),
            Obs   => (A => 66_191, B => 6_554, L => 19_661, Max_Age => Max_Age));
      begin
         return Candidate.Check.Persistence = Persistence;
      end;
   exception
      when Ada.Assertions.Assertion_Error =>
         return False;
   end Accepts;

   procedure Test_Voter is
      P : constant VT.Voter_Params := VT.Default_Params;
      S : VT.Voter_State := VT.Initial_State;
      O : VT.Voted;
   begin
      --  VT-01 triplex, all agree
      VT.Step (S, P, Rd (1000, 1010, 1005), 0, O);
      Check ("VT-01a triplex median",
             O.Value = 1005 and then O.Level = Triplex and then O.Valid
             and then O.Trusted and then not O.Aided);
      Check ("VT-01b the observer is anchored by the first trusted frame",
             S.Obs.Initialized and then S.Obs.Age = 0);

      --  VT-02 a hard-over on sensor 3 is masked, frame by frame
      for K in 1 .. 7 loop
         VT.Step (S, P, Rd (1000, 1010, 40_000), 0, O);
         Check ("VT-02 masked by the median, frame" & K'Image,
                O.Value = 1010 and then O.Level = Triplex
                and then O.Check.Result = CC.Located and then O.Trusted);
      end loop;
      Check ("VT-02b the observer was not dragged toward the bad sensor",
             S.Obs.Estimate < 2_000);

      --  VT-03 the exclusion takes effect in the SAME frame it is decided
      VT.Step (S, P, Rd (1000, 1010, 40_000), 0, O);
      Check ("VT-03a sensor 3 failed at the 8th located frame",
             S.Check (3).Health = Failed and then O.Check.Newly_Failed);
      Check ("VT-03b value is already the midpoint of the two good sensors",
             O.Value = 1005 and then O.Level = Duplex and then O.Trusted);

      --  VT-04 duplex, the pair agrees: trusted, not aided
      VT.Step (S, P, Rd (1000, 1010, 1005), 0, O);
      Check ("VT-04 duplex after exclusion",
             O.Level = Duplex and then O.Value = 1005 and then O.Trusted
             and then not O.Aided);

      --  VT-05 reference-aided duplex: sensor 2 now hard-over, sensor 3 gone
      for K in 1 .. 7 loop
         VT.Step (S, P, Rd (1000, 30_000, 0, VC => False), 0, O);
         Check ("VT-05 aided frame" & K'Image,
                O.Aided and then O.Level = Simplex and then O.Value = 1000
                and then (not O.Trusted) and then O.Check.Outlier = 2
                and then S.Check (2).Health = Suspect);
      end loop;
      VT.Step (S, P, Rd (1000, 30_000, 0, VC => False), 0, O);
      Check ("VT-05b the 8th located frame excludes sensor 2",
             S.Check (2).Health = Failed and then O.Check.Newly_Failed
             and then O.Value = 1000 and then O.Level = Simplex);

      --  VT-06 afterwards: one source, no aid needed
      VT.Step (S, P, Rd (1000, 30_000, 0, VC => False), 0, O);
      Check ("VT-06 single source afterwards",
             O.Level = Simplex and then O.Value = 1000 and then not O.Aided
             and then not O.Trusted);

      --  VT-07 duplex, unresolved, observer never initialized
      S := VT.Initial_State;
      VT.Step (S, P, Rd (1000, 21_000, 0, VC => False), 0, O);
      Check ("VT-07 unresolved duplex: midpoint, reported",
             O.Value = 11_000 and then O.Level = Duplex
             and then O.Check.Result = CC.Unresolved
             and then (not O.Aided) and then not O.Trusted);

      --  VT-08 nothing usable
      S := VT.Initial_State;
      VT.Step (S, P, Rd (1, 2, 3, False, False, False), 0, O);
      Check ("VT-08 lost",
             O.Level = Lost and then (not O.Valid) and then O.Value = 0
             and then O.Check.Result = CC.Insufficient and then not O.Trusted);

      --  VT-09 the trust rule, row by row
      S := VT.Initial_State;
      VT.Step (S, P, Rd (0, 20_000, 40_000), 0, O);
      Check ("VT-09a three usable but unresolved: not trusted",
             O.Level = Triplex and then O.Check.Result = CC.Unresolved
             and then not O.Trusted);
      S := VT.Initial_State;
      VT.Step (S, P, Rd (1000, 0, 0, VB => False, VC => False), 0, O);
      Check ("VT-09b one usable: not trusted",
             O.Level = Simplex and then not O.Trusted);
      S := VT.Initial_State;
      VT.Step (S, P, Rd (1000, 1_010, 0, VC => False), 0, O);
      Check ("VT-09c two usable and agreeing: trusted",
             O.Level = Duplex and then O.Trusted);

      --  VT-10 the observer keeps its age at 0 while trusted frames continue,
      --  and ages while they do not
      S := VT.Initial_State;
      VT.Step (S, P, Rd (1000, 1_010, 1_005), 0, O);
      VT.Step (S, P, Rd (1000, 1_010, 1_005), 0, O);
      Check ("VT-10a age 0 while trusted", S.Obs.Age = 0);
      VT.Step (S, P, Rd (0, 20_000, 40_000), 0, O);
      Check ("VT-10b age 1 after an untrusted frame", S.Obs.Age = 1);
      VT.Step (S, P, Rd (1000, 1_010, 1_005), 0, O);
      Check ("VT-10c a trusted frame resets it", S.Obs.Age = 0);

      --  VT-11 the aided case from every pair of positions and either outlier
      declare
         type Pair is record
            First  : Sensor_Id;
            Second : Sensor_Id;
            Third  : Sensor_Id;
         end record;
         Pairs : constant array (1 .. 3) of Pair := ((1, 2, 3), (1, 3, 2), (2, 3, 1));
         All_OK : Boolean := True;
         Cases  : Natural := 0;
      begin
         for Pr in Pairs'Range loop
            for Which in 1 .. 2 loop
               declare
                  Sx : VT.Voter_State := VT.Initial_State;
                  R  : Reading_Set := Rd (1000, 1000, 1000);
                  Outlier : constant Sensor_Id :=
                    (if Which = 1 then Pairs (Pr).First else Pairs (Pr).Second);
               begin
                  Cases := Cases + 1;
                  VT.Step (Sx, P, R, 0, O);                    --  three agree
                  R (Pairs (Pr).Third).Valid := False;
                  VT.Step (Sx, P, R, 0, O);                    --  the pair, trusted
                  R (Outlier).Value := 30_000;
                  VT.Step (Sx, P, R, 0, O);                    --  outlier hard-over
                  if not (O.Aided and then O.Level = Simplex and then O.Value = 1000
                          and then O.Check.Outlier = Outlier)
                  then
                     All_OK := False;
                  end if;
               end;
            end loop;
         end loop;
         Check ("VT-11 reference-aided duplex, all" & Cases'Image & " position cases", All_OK);
      end;

      --  VT-12 the exclusion still completes at the boundary of the coupling
      --        rule (Persistence 8, Max_Age 7: the reference lives just long enough)
      declare
         Tight : constant VT.Voter_Params :=
           (Check => (Threshold => 6_554, Persistence => 8),
            Obs   => (A => 66_191, B => 6_554, L => 19_661, Max_Age => 7));
         Sy : VT.Voter_State := VT.Initial_State;
         R  : Reading_Set := Rd (1000, 1000, 1000, VC => False);
      begin
         VT.Step (Sy, Tight, Rd (1000, 1000, 1000), 0, O);
         VT.Step (Sy, Tight, R, 0, O);
         R (2).Value := 30_000;
         for K in 1 .. 8 loop
            VT.Step (Sy, Tight, R, 0, O);
         end loop;
         Check ("VT-12 sensor 2 is excluded with the tightest legal parameters",
                Sy.Check (2).Health = Failed and then O.Value = 1000);
      end;

      --  VT-13 the coupling rule is a predicate of the parameters:
      --        Persistence - 1 <= Max_Age
      Check ("VT-13a default parameters are accepted", Accepts (8, 8));
      Check ("VT-13b boundary accepted: 8 and 7", Accepts (8, 7));
      Check ("VT-13c one short is rejected: 8 and 6", not Accepts (8, 6));
      Check ("VT-13d persistence 1 is always accepted", Accepts (1, 1));
      Check ("VT-13e upper limit accepted: 24 and 23", Accepts (24, 23));
      Check ("VT-13f upper limit one short is rejected: 24 and 22", not Accepts (24, 22));
   end Test_Voter;

   --  MD: Modes

   Healthy_Inputs : constant MD.Mode_Inputs :=
     (Level => Triplex, Check_Result => CC.All_Agree, Failed_Sensors => 0,
      Loop_Status => CTL.Nominal, Healthy_Lrus => 3, Actuator_Degraded => False);

   procedure Test_Modes is
      S : MD.Mode_State := MD.Initial_State;
      I : MD.Mode_Inputs;
   begin
      --  MD-01 the demand table, row by row
      Check ("MD-01a healthy: Normal", MD.Demand (0, 0, 0, Healthy_Inputs) = MD.Normal);

      I := Healthy_Inputs; I.Failed_Sensors := 1;
      Check ("MD-01b one sensor failed: Degraded_1", MD.Demand (0, 0, 0, I) = MD.Degraded_1);
      I := Healthy_Inputs; I.Healthy_Lrus := 2;
      Check ("MD-01c two LRUs: Degraded_1", MD.Demand (0, 0, 0, I) = MD.Degraded_1);
      I := Healthy_Inputs; I.Actuator_Degraded := True;
      Check ("MD-01d actuator path degraded: Degraded_1", MD.Demand (0, 0, 0, I) = MD.Degraded_1);
      I := Healthy_Inputs; I.Failed_Sensors := 1; I.Actuator_Degraded := True;
      Check ("MD-01e sensor and actuator: Degraded_2", MD.Demand (0, 0, 0, I) = MD.Degraded_2);

      I := Healthy_Inputs; I.Failed_Sensors := 2;
      Check ("MD-01f two sensors failed: Direct", MD.Demand (0, 0, 0, I) = MD.Direct);
      I := Healthy_Inputs; I.Healthy_Lrus := 1;
      Check ("MD-01g one LRU: Direct", MD.Demand (0, 0, 0, I) = MD.Direct);
      I := Healthy_Inputs; I.Healthy_Lrus := 0;
      Check ("MD-01h no LRU: Fail_Passive", MD.Demand (0, 0, 0, I) = MD.Fail_Passive);
      I := Healthy_Inputs; I.Failed_Sensors := 3;
      Check ("MD-01i three sensors failed: Direct (Fail_Passive comes from the lost counter)",
             MD.Demand (0, 0, 0, I) = MD.Direct);

      --  MD-02 each persistence limit, below and at the boundary
      Check ("MD-02a unresolved 3: Normal", MD.Demand (3, 0, 0, Healthy_Inputs) = MD.Normal);
      Check ("MD-02b unresolved 4: Degraded_2", MD.Demand (4, 0, 0, Healthy_Inputs) = MD.Degraded_2);
      Check ("MD-02c saturated 9: Normal", MD.Demand (0, 9, 0, Healthy_Inputs) = MD.Normal);
      Check ("MD-02d saturated 10: Degraded_2", MD.Demand (0, 10, 0, Healthy_Inputs) = MD.Degraded_2);
      Check ("MD-02e lost 11: Normal", MD.Demand (0, 0, 11, Healthy_Inputs) = MD.Normal);
      Check ("MD-02f lost 12: Fail_Passive", MD.Demand (0, 0, 12, Healthy_Inputs) = MD.Fail_Passive);
      Check ("MD-02g the worst row wins",
             MD.Demand (4, 10, 12, Healthy_Inputs) = MD.Fail_Passive);

      --  MD-03 the latch: the mode never improves
      I := Healthy_Inputs; I.Failed_Sensors := 1;
      MD.Update (S, I);
      Check ("MD-03a latches Degraded_1", S.Current = MD.Degraded_1);
      MD.Update (S, Healthy_Inputs);
      Check ("MD-03b a healthy frame does not undo it", S.Current = MD.Degraded_1);
      I := Healthy_Inputs; I.Failed_Sensors := 2;
      MD.Update (S, I);
      Check ("MD-03c worsens to Direct", S.Current = MD.Direct);
      I.Failed_Sensors := 1;
      MD.Update (S, I);
      Check ("MD-03d a milder demand does not improve it", S.Current = MD.Direct);

      --  MD-04 counters: consecutive frames, reset when the condition ends
      S := MD.Initial_State;
      I := Healthy_Inputs; I.Check_Result := CC.Unresolved;
      for K in 1 .. 3 loop
         MD.Update (S, I);
      end loop;
      Check ("MD-04a three unresolved frames: counter 3, still Normal",
             S.Unresolved_Frames = 3 and then S.Current = MD.Normal);
      MD.Update (S, Healthy_Inputs);
      Check ("MD-04b the counter resets", S.Unresolved_Frames = 0 and then S.Current = MD.Normal);
      for K in 1 .. 4 loop
         MD.Update (S, I);
      end loop;
      Check ("MD-04c four consecutive frames: Degraded_2", S.Current = MD.Degraded_2);

      S := MD.Initial_State;
      I := Healthy_Inputs; I.Loop_Status := CTL.Saturated;
      for K in 1 .. 9 loop
         MD.Update (S, I);
      end loop;
      Check ("MD-04d nine saturated frames: not yet", S.Current = MD.Normal);
      MD.Update (S, I);
      Check ("MD-04e tenth saturated frame: Degraded_2", S.Current = MD.Degraded_2);

      --  MD-05 a long loss of every sensor ends in Fail_Passive at frame 12
      S := MD.Initial_State;
      I := Healthy_Inputs; I.Level := Lost;
      for K in 1 .. 11 loop
         MD.Update (S, I);
      end loop;
      Check ("MD-05a eleven lost frames: not yet", S.Current = MD.Normal and then S.Lost_Frames = 11);
      MD.Update (S, I);
      Check ("MD-05b twelfth lost frame: Fail_Passive",
             S.Current = MD.Fail_Passive and then S.Lost_Frames = 12);
      MD.Update (S, Healthy_Inputs);
      Check ("MD-05c Fail_Passive is not undone", S.Current = MD.Fail_Passive);
      I.Level := Lost;
      for K in 1 .. 40 loop
         MD.Update (S, I);
      end loop;
      Check ("MD-05d the counter saturates at 24", S.Lost_Frames = 24);

      --  MD-06 Reset is the only way back
      MD.Reset (S);
      Check ("MD-06 Reset returns to the initial state", S = MD.Initial_State);

      --  MD-07 Count_Failed
      Check ("MD-07a none", MD.Count_Failed ((Healthy, Healthy, Healthy)) = 0);
      Check ("MD-07b one", MD.Count_Failed ((Healthy, Failed, Healthy)) = 1);
      Check ("MD-07c suspect is not failed", MD.Count_Failed ((Suspect, Failed, Suspect)) = 1);
      Check ("MD-07d three", MD.Count_Failed ((Failed, Failed, Failed)) = 3);

      --  MD-08 the profiles never increase authority as the mode worsens
      declare
         Monotone : Boolean := True;
      begin
         for A in MD.Mode loop
            for B in MD.Mode loop
               if A <= B
                 and then (MD.Profile_Of (B).Gain_Scale > MD.Profile_Of (A).Gain_Scale
                           or else MD.Profile_Of (B).Limit_Scale > MD.Profile_Of (A).Limit_Scale)
               then
                  Monotone := False;
               end if;
            end loop;
         end loop;
         Check ("MD-08 profiles never increase authority as the mode worsens", Monotone);
      end;
      Check ("MD-08b only Fail_Passive stops the law",
             MD.Profile_Of (MD.Direct).Active and then not MD.Profile_Of (MD.Fail_Passive).Active);
      Check ("MD-08c only Direct and Fail_Passive leave the schedule",
             MD.Profile_Of (MD.Degraded_2).Scheduled
             and then not MD.Profile_Of (MD.Direct).Scheduled);

      --  MD-09 Scaled_Params
      declare
         Base : constant Fsac.Control.Params.Pitch_Rate_Params :=
           (Kq => 131_072, Ki_Dt => 655, Out_Limit => 32_768,
            Integrator_Limit => 6_554, Rate_Limit => 3_277);
         use type Fsac.Control.Params.Pitch_Rate_Params;
         N  : constant Fsac.Control.Params.Pitch_Rate_Params :=
           MD.Scaled_Params (Base, MD.Profile_Of (MD.Normal));
         D2 : constant Fsac.Control.Params.Pitch_Rate_Params :=
           MD.Scaled_Params (Base, MD.Profile_Of (MD.Degraded_2));
         Dr : constant Fsac.Control.Params.Pitch_Rate_Params :=
           MD.Scaled_Params (Base, MD.Profile_Of (MD.Direct));
         Tiny : constant Fsac.Control.Params.Pitch_Rate_Params :=
           (Kq => 100, Ki_Dt => 0, Out_Limit => 2, Integrator_Limit => 1, Rate_Limit => 1);
         T  : constant Fsac.Control.Params.Pitch_Rate_Params :=
           MD.Scaled_Params (Tiny, MD.Profile_Of (MD.Direct));
      begin
         Check ("MD-09a Normal profile is the identity", N = Base);
         --  0.70 = 45_875: Kq 131072 -> 91750, Out 32768 -> 22937,
         --  Rate 3277 -> 2293, Ki_Dt 655 -> 458 (each truncated toward zero)
         Check ("MD-09b Degraded_2 scales by 0.70",
                D2.Kq = 91_750 and then D2.Out_Limit = 22_937
                and then D2.Rate_Limit = 2_293 and then D2.Ki_Dt = 458);
         Check ("MD-09c the integrator never asks for more than the output",
                D2.Integrator_Limit <= D2.Out_Limit);
         --  0.50: Kq 65536, Out 16384, Rate 1638, integrator unchanged (6554 <= 16384)
         Check ("MD-09d Direct scales by 0.50",
                Dr.Kq = 65_536 and then Dr.Out_Limit = 16_384
                and then Dr.Rate_Limit = 1_638 and then Dr.Integrator_Limit = 6_554);
         Check ("MD-09e the floors keep a tiny set valid",
                T.Kq = 100 and then T.Out_Limit >= 1 and then T.Rate_Limit >= 1
                and then T.Integrator_Limit <= T.Out_Limit);
      end;

      --  MD-10 the precondition of Scaled_Params: a profile that is not Active
      --        (Fail_Passive) cannot be applied to the damper parameters
      declare
         Base : constant Fsac.Control.Params.Pitch_Rate_Params :=
           (Kq => 131_072, Ki_Dt => 655, Out_Limit => 32_768,
            Integrator_Limit => 6_554, Rate_Limit => 3_277);
         Rejected : Boolean := False;
      begin
         begin
            declare
               Unused : constant Fsac.Control.Params.Pitch_Rate_Params :=
                 MD.Scaled_Params (Base, MD.Profile_Of (MD.Fail_Passive));
            begin
               Rejected := Unused.Kq = 0;   --  not reached when the contract is checked
            end;
         exception
            when Ada.Assertions.Assertion_Error =>
               Rejected := True;
         end;
         Check ("MD-10 Scaled_Params refuses the Fail_Passive profile", Rejected);
      end;

      --  MD-12 randomized: whatever the inputs, the mode never improves, the
      --  counters stay inside their bounds and the latch equals max(old, demand)
      declare
         Monotone  : Boolean := True;
         Bounded   : Boolean := True;
         Exact     : Boolean := True;
         Prev_Mode : MD.Mode;
         Frames    : Natural := 0;
      begin
         for Run in 1 .. 40 loop
            MD.Reset (S);
            for K in 1 .. 300 loop
               I := (Level             =>
                       (if Random_Below (16) = 0 then Lost else Triplex),
                     Check_Result      =>
                       CC.Decision'Val (Random_Below (4)),
                     Failed_Sensors    =>
                       (if Random_Below (8) = 0 then Random_Below (4) else 0),
                     Loop_Status       =>
                       CTL.Loop_Status'Val (Random_Below (4)),
                     Healthy_Lrus      =>
                       (if Random_Below (50) = 0 then Random_Below (4) else 3),
                     Actuator_Degraded => Random_Below (20) = 0);
               Prev_Mode := S.Current;
               MD.Update (S, I);
               Frames := Frames + 1;

               if S.Current < Prev_Mode then
                  Monotone := False;
               end if;
               if S.Unresolved_Frames > 24 or else S.Saturated_Frames > 24
                 or else S.Lost_Frames > 24
               then
                  Bounded := False;
               end if;
               if S.Current /= MD.Mode'Max
                    (Prev_Mode,
                     MD.Demand (S.Unresolved_Frames, S.Saturated_Frames,
                                S.Lost_Frames, I))
               then
                  Exact := False;
               end if;
            end loop;
         end loop;
         Check ("MD-12a the mode never improves over" & Frames'Image & " random frames", Monotone);
         Check ("MD-12b counters stay within 24", Bounded);
         Check ("MD-12c the latch is exactly max (old, demand)", Exact);
      end;
   end Test_Modes;

   --  IT: integration fault campaign (Voter -> Modes -> Pitch_Rate_Damper)

   --  40 frames. The three sensors read 1000, 1010 and 1005 (rad/s * 65536,
   --  tiny differences). The commanded rate is 3000. The "plant" is open loop
   --  on purpose: the measurement does not react to the surface command, so
   --  the only difference between two runs is the effect of the fault.

   type Cmd_Trace is array (1 .. 40) of Surface_Cmd;

   procedure Campaign
     (Fault_From    : Natural;      --  first frame of the sensor 3 hard-over (0: none)
      Blackout_From : Natural;      --  first frame with every sensor invalid (0: none)
      Use_Voter     : Boolean;      --  False: a plain average of the three readings
      Trace         : out Cmd_Trace;
      Final_Mode    : out MD.Mode;
      Sensor_3_Failed : out Boolean;
      First_Fail_Passive : out Natural)
   is
      Base : constant Fsac.Control.Params.Pitch_Rate_Params :=
        (Kq => 131_072, Ki_Dt => 655, Out_Limit => 32_768,
         Integrator_Limit => 6_554, Rate_Limit => 3_277);

      VS    : VT.Voter_State := VT.Initial_State;
      MS    : MD.Mode_State := MD.Initial_State;
      DS    : DMP.Damper_State := DMP.Initial_State;
      Out_D : DMP.Damper_Output := (Cmd => 0, Status => CTL.Nominal);
      Vo    : VT.Voted;
      R     : Reading_Set;
      Meas  : Body_Rate;
      Valid : Boolean;
      Pr    : Fsac.Control.Params.Pitch_Rate_Params;
   begin
      First_Fail_Passive := 0;

      for K in Trace'Range loop
         R := Rd (1000, 1_010, 1_005);
         if Fault_From /= 0 and then K >= Fault_From then
            R (3).Value := 40_000;
         end if;
         if Blackout_From /= 0 and then K >= Blackout_From then
            R (1).Valid := False;
            R (2).Valid := False;
            R (3).Valid := False;
         end if;

         if Use_Voter then
            VT.Step (VS, VT.Default_Params, R, DS.Last_Cmd, Vo);
            Meas  := Vo.Value;
            Valid := Vo.Valid;
            MD.Update
              (MS,
               (Level             => Vo.Level,
                Check_Result      => Vo.Check.Result,
                Failed_Sensors    => MD.Count_Failed (CC.Health_Of (VS.Check)),
                Loop_Status       => Out_D.Status,
                Healthy_Lrus      => 3,
                Actuator_Degraded => False));
         else
            Meas  := Body_Rate
              ((Integer (R (1).Value) + Integer (R (2).Value) + Integer (R (3).Value)) / 3);
            Valid := True;
         end if;

         if MS.Current = MD.Fail_Passive and then First_Fail_Passive = 0 then
            First_Fail_Passive := K;
         end if;

         if MD.Profile_Of (MS.Current).Active then
            Pr := MD.Scaled_Params (Base, MD.Profile_Of (MS.Current));
            DMP.Rebase (DS, Pr);   --  the state follows the limits of the new mode
            DMP.Step (DS, Pr, (Q_Cmd => 3_000, Q_Meas => Meas, Valid => Valid), Out_D);
         else
            --  Fail_Passive: the law is NOT run and the damper state is NOT
            --  re-based. The surface is held at its last command.
            Out_D := (Cmd => DS.Last_Cmd, Status => CTL.Input_Invalid);
         end if;

         Trace (K) := Out_D.Cmd;
      end loop;

      Final_Mode      := MS.Current;
      Sensor_3_Failed := VS.Check (3).Health = Failed;
   end Campaign;

   procedure Test_Integration is
      Clean, Faulted, Naive, Dark : Cmd_Trace;
      M : MD.Mode;
      F3 : Boolean;
      FP : Natural;
      Max_Diff : Natural := 0;
      Max_Naive : Natural := 0;
      Bounded : Boolean := True;
      Smooth  : Boolean := True;
   begin
      Campaign (0, 0, True, Clean, M, F3, FP);
      Check ("IT-01a fault-free run stays Normal and never fails a sensor",
             M = MD.Normal and then not F3 and then FP = 0);

      --  IT-02 sensor 3 stuck at a huge value from frame 6 on
      Campaign (6, 0, True, Faulted, M, F3, FP);
      Check ("IT-02a the faulty sensor is excluded", F3);
      Check ("IT-02b the mode latches Degraded_1", M = MD.Degraded_1 and then FP = 0);

      for K in Clean'Range loop
         Max_Diff := Natural'Max
           (Max_Diff, abs (Integer (Faulted (K)) - Integer (Clean (K))));

         if abs (Faulted (K)) > 32_768 then
            Bounded := False;
         end if;
         if K > 1 and then abs (Integer (Faulted (K)) - Integer (Faulted (K - 1))) > 3_277 then
            Smooth := False;
         end if;
      end loop;
      Check ("IT-02c the command differs from the fault-free run by at most 50 raw"
             & " (largest:" & Max_Diff'Image & ")", Max_Diff <= 50);
      Check ("IT-02d the command stays within the output limit", Bounded);
      Check ("IT-02e the command never moves faster than the rate limit", Smooth);

      --  IT-03 the same fault with a plain average of the sensors (no voter)
      Campaign (6, 0, False, Naive, M, F3, FP);
      for K in Clean'Range loop
         Max_Naive := Natural'Max
           (Max_Naive, abs (Integer (Naive (K)) - Integer (Clean (K))));
      end loop;
      Check ("IT-03 without the voter the same fault moves the command by over 10000"
             & " (largest:" & Max_Naive'Image & ")", Max_Naive > 10_000);

      --  IT-04 every sensor lost from frame 10: the damper holds, the mode
      --        reverts to Fail_Passive on the 12th lost frame (frame 21)
      Campaign (0, 10, True, Dark, M, F3, FP);
      Check ("IT-04a Fail_Passive is reached on the 12th lost frame (frame 21)", FP = 21);
      Check ("IT-04b final mode is Fail_Passive", M = MD.Fail_Passive);
      declare
         Held : Boolean := True;
      begin
         for K in 10 .. 40 loop
            if Dark (K) /= Dark (9) then
               Held := False;
            end if;
         end loop;
         Check ("IT-04c the command is held, unchanged, from the first lost frame", Held);
      end;
   end Test_Integration;

begin
   Put_Line ("FSAC signal management and mode logic tests");

   Test_MVS;
   Test_Cross_Check;
   Test_Observer;
   Test_Voter;
   Test_Modes;
   Test_Integration;

   New_Line;
   Put_Line ("passed:" & Natural'Image (Passed));
   Put_Line ("failed:" & Natural'Image (Failures));

   if Failures > 0 then
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   end if;
end Test_Signal_Mgmt;