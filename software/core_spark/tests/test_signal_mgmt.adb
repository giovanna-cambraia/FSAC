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