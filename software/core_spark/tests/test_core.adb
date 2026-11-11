--  ===========================================================================
--  FSAC - Flight Stability Augmentation Computer
--  ===========================================================================
--  File        : software/core_spark/tests/test_core.adb
--  Unit        : Test_Core (main program, host only)
--  Language    : Ada 2012
--  Purpose     : Requirements-based tests of the SPARK core (DO-178C 6.4)
--  Covers      : Fsac.Fixed_Math, Fsac.Control.Gain_Schedule,
--                Fsac.Control.Pitch_Rate_Damper

--  WHAT THESE TESTS ARE FOR
   -- the proof (GNATprove) shows that the code cannot fail at run time and that it satisfies its contracts; tests answer two other questions:
   --      1. does the code compute the RIGHT numbers? a contract can be satisfied by a wrong but legal answer
   --      2. do the expected behaviours happen in sequence over many frames (step response, windup, hold on invalid input)?
   -- DO-178C asks for both kinds of evidence, which is why a fully proved unit still has tests: proof covers all inputs for the properties stated, tests check the behaviour 
   -- against the requirement text

--  HOW THE EXPECTED VALUES WERE OBTAINED
   -- every expected number below was derived by hand from the control law and the Q16 rules (truncation toward zero), with the intermediate steps written next to the test;
   -- hand derivation is acceptable for a first baseline, but it is not independent enough for certification credit, the next step (verification/requirements_tests/
   -- reference_model.py) is a separate Python model of the same law, written from the requirement text only, whose output replaces these constants; tests that disagree
   -- with the model are a finding for review, not a reason to edit either
   
--  HOW TO BUILD AND RUN (from software/core_spark/tests/)
   -- gnatmake -gnat2012 -gnata -gnato -o test_core test_core.adb \-I../src -I../src/types -I../src/math -I../src/params -I../src/control./test_core
   -- -gnata is required: it makes the compiler evaluate the predicates and contracts during the tests, so a contract violation is reported as a failure at the point where 
   -- it happens

--  NOTE ON THE RESTRICTIONS FILE
   -- this program is not flight code; it uses Ada.Text_IO, which fsac.adc forbids in the core, so it is built without fsac.adc
   --  TEST IDS (map to requirements in traceability/links/)
   --    N-xx   numeric kernel         HLR-NUM-0010 .. 0018
   --    G-xx   gain schedule          HLR-CTL-0013 .. 0019
   --    D-xx   pitch-rate damper      HLR-CTL-0020 .. 0034

with Ada.Text_IO;      use Ada.Text_IO;
with Ada.Command_Line;

with Fsac.Types;                 use Fsac.Types;
with Fsac.Fixed_Math;            use Fsac.Fixed_Math;
with Fsac.Control;               use Fsac.Control;
with Fsac.Control.Params;        use Fsac.Control.Params;
with Fsac.Control.Gain_Schedule; use Fsac.Control.Gain_Schedule;
with Fsac.Control.Pitch_Rate_Damper;
use Fsac.Control.Pitch_Rate_Damper;

procedure Test_Core is

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

   procedure Check_Q (Name : String; Got : Q16; Expected : Q16) is
   begin
      if Got = Expected then
         Passed := Passed + 1;
      else
         Failed := Failed + 1;
         Put_Line
           ("FAIL  " & Name & ": got" & Q16'Image (Got)
            & ", expected" & Q16'Image (Expected));
      end if;
   end Check_Q;

   --  N: numeric kernel (corner values)
   procedure Test_Numeric is
      Half : constant Q16 := 32_768;   --  0.5
   begin
      --  N-01 Saturate
      Check_Q ("N-01a Saturate inside range", Saturate (5), 5);
      Check_Q ("N-01b Saturate above", Saturate (Wide (Q16'Last) + 1), Q16'Last);
      Check_Q ("N-01c Saturate below", Saturate (Wide (Q16'First) - 1), Q16'First);

      --  N-02 Add_Sat, Sub_Sat
      Check_Q ("N-02a Add normal", Add_Sat (100, 200), 300);
      Check_Q ("N-02b Add saturates up", Add_Sat (Q16'Last, 1), Q16'Last);
      Check_Q ("N-02c Add saturates down", Add_Sat (Q16'First, -1), Q16'First);
      Check_Q ("N-02d Sub saturates down", Sub_Sat (Q16'First, 1), Q16'First);
      Check_Q ("N-02e Sub exact at limit", Sub_Sat (0, Q16'First), Q16'Last);

      --  N-03 Mul_Q (raw: 65536 = 1.0)
      Check_Q ("N-03a 1.0 * 1.0", Mul_Q (Q16_One, Q16_One), Q16_One);
      Check_Q ("N-03b 2.0 * 3.0", Mul_Q (131_072, 196_608), 393_216);
      Check_Q ("N-03c 0.5 * 0.5", Mul_Q (Half, Half), 16_384);
      Check_Q ("N-03d -1.0 * 1.0", Mul_Q (-Q16_One, Q16_One), -Q16_One);
      --  Truncation toward zero, symmetric in sign:
      --  3 * 32768 / 65536 = 1.5 -> 1 ; -3 * 32768 / 65536 = -1.5 -> -1
      Check_Q ("N-03e trunc positive", Mul_Q (3, Half), 1);
      Check_Q ("N-03f trunc negative", Mul_Q (-3, Half), -1);
      Check_Q ("N-03g tiny product is zero", Mul_Q (1, 1), 0);
      Check_Q ("N-03h tiny negative product is zero", Mul_Q (-1, 1), 0);
      Check_Q ("N-03i saturates up", Mul_Q (Q16'Last, Q16'Last), Q16'Last);
      Check_Q ("N-03j saturates down", Mul_Q (Q16'First, Q16'Last), Q16'First);

      --  N-04 Neg, Abs_Q (symmetric range: no overflow at the extremes)
      Check_Q ("N-04a Neg of Last", Neg (Q16'Last), Q16'First);
      Check_Q ("N-04b Neg of First", Neg (Q16'First), Q16'Last);
      Check_Q ("N-04c Abs of First", Abs_Q (Q16'First), Q16'Last);
      Check_Q ("N-04d Abs of -5", Abs_Q (-5), 5);

      --  N-05 Clamp
      Check_Q ("N-05a Clamp inside", Clamp (5, 0, 10), 5);
      Check_Q ("N-05b Clamp below", Clamp (-5, 0, 10), 0);
      Check_Q ("N-05c Clamp above", Clamp (15, 0, 10), 10);
      Check_Q ("N-05d Clamp at low edge", Clamp (0, 0, 10), 0);
      Check_Q ("N-05e Clamp at high edge", Clamp (10, 0, 10), 10);

      --  N-06 Narrowing conversions
      Check_Q ("N-06a To_Body_Rate high", To_Body_Rate (9 * 65_536),
               Body_Rate'Last);
      Check_Q ("N-06b To_Body_Rate low", To_Body_Rate (-9 * 65_536),
               Body_Rate'First);
      Check_Q ("N-06c To_Body_Rate inside", To_Body_Rate (1_000), 1_000);
      Check_Q ("N-06d To_Surface_Cmd high", To_Surface_Cmd (2 * 65_536),
               Surface_Cmd'Last);
   end Test_Numeric;


   --  G: gain schedule
   --  Table used by all G tests (breakpoints in kPa, gains real / raw):
   --
   --    i    q (kPa)   Kq real   Kq raw     Ki_Dt raw   Inv_Span (raw)
   --    1       0       0.5       32_768        500       6_554  (1/10)
   --    2      10       1.0       65_536      1_000       6_554  (1/10)
   --    3      20       2.0      131_072      1_000       6_554  (1/10)
   --    4      30       3.0      196_608      1_500       4_369  (1/15)
   --    5      45       3.0      196_608      1_500       4_369  (1/15)
   --    6      60       2.0      131_072      1_000       2_185  (1/30)
   --    7      90       1.5       98_304      1_000       2_185  (1/30)
   --    8     120       1.0       65_536        500       (none)
   --
   --  the gain rises, stays flat, then falls: both slopes are exercised.

   Sched : constant Valid_Gain_Schedule :=
     (Q_Break  => (0, 655_360, 1_310_720, 1_966_080,
                   2_949_120, 3_932_160, 5_898_240, 7_864_320),
      Kq       => (32_768, 65_536, 131_072, 196_608,
                   196_608, 131_072, 98_304, 65_536),
      Ki_Dt    => (500, 1_000, 1_000, 1_500, 1_500, 1_000, 1_000, 500),
      Inv_Span => (6_554, 6_554, 6_554, 4_369, 4_369, 2_185, 2_185));

   function KPa (Whole : Natural; Frac_Raw : Natural := 0)
     return Dyn_Pressure is
     (Dyn_Pressure (Whole * 65_536 + Frac_Raw));

   procedure Test_Gain_Schedule is
      G : Scheduled_Gains;
   begin
      --  G-01 clamped ends (P3) and exact breakpoints (P2)
      G := Schedule_Gain (Sched, 0);
      Check_Q ("G-01a Kq at first breakpoint", G.Kq, 32_768);
      Check_Q ("G-01b Ki at first breakpoint", G.Ki_Dt, 500);

      G := Schedule_Gain (Sched, KPa (120));
      Check_Q ("G-01c Kq at last breakpoint", G.Kq, 65_536);

      G := Schedule_Gain (Sched, Dyn_Pressure'Last);   --  128 kPa
      Check_Q ("G-01d Kq above table is clamped", G.Kq, 65_536);
      Check_Q ("G-01e Ki above table is clamped", G.Ki_Dt, 500);

      G := Schedule_Gain (Sched, KPa (10));
      Check_Q ("G-02a Kq exactly at breakpoint 2", G.Kq, 65_536);
      G := Schedule_Gain (Sched, KPa (30));
      Check_Q ("G-02b Kq exactly at breakpoint 4", G.Kq, 196_608);
      Check_Q ("G-02c Ki exactly at breakpoint 4", G.Ki_Dt, 1_500);
      G := Schedule_Gain (Sched, KPa (60));
      Check_Q ("G-02d Kq exactly at breakpoint 6", G.Kq, 131_072);

      --  G-03 rising segment, q = 5 kPa (middle of segment 1)
      --    offset = 5 kPa = 327_680 raw
      --    t      = 327_680 * 6_554 / 65_536 = 32_770   (ideal 32_768)
      --    Kq     = 32_768 + (32_768 * 32_770) / 65_536 = 32_768 + 16_385
      --           = 49_153                              (ideal 49_152)
      --    Ki_Dt  = 500 + (500 * 32_770) / 65_536 = 500 + 250 = 750
      G := Schedule_Gain (Sched, KPa (5));
      Check_Q ("G-03a rising Kq", G.Kq, 49_153);
      Check_Q ("G-03b rising Ki", G.Ki_Dt, 750);

      --  G-04 falling segment, q = 52.5 kPa (middle of segment 5)
      --    offset = 7.5 kPa = 491_520 raw
      --    t      = 491_520 * 4_369 / 65_536 = 32_767.5 -> 32_767
      --    Kq     = 196_608 + (-65_536 * 32_767) / 65_536
      --           = 196_608 - 32_767 = 163_841          (ideal 163_840)
      G := Schedule_Gain (Sched, KPa (52, 32_768));
      Check_Q ("G-04 falling Kq", G.Kq, 163_841);

      --  G-05 sweep 0 .. 128 kPa in 0.25 kPa steps
      --    (a) results stay inside the table's overall bounds (P1)
      --    (b) in the rising part (0 .. 30 kPa) the gain never decreases
      declare
         Prev_Kq : Q16 := 0;
         OK_Bounds   : Boolean := True;
         OK_Monotone : Boolean := True;
      begin
         for I in 0 .. 512 loop
            declare
               Q : constant Dyn_Pressure := Dyn_Pressure (I * 16_384);
               R : constant Scheduled_Gains := Schedule_Gain (Sched, Q);
            begin
               if R.Kq < 32_768 or else R.Kq > 196_608
                 or else R.Ki_Dt < 500 or else R.Ki_Dt > 1_500
               then
                  OK_Bounds := False;
               end if;

               if I <= 120 then
                  if R.Kq < Prev_Kq then
                     OK_Monotone := False;
                  end if;
                  Prev_Kq := R.Kq;
               end if;
            end;
         end loop;

         Check ("G-05a sweep stays inside table bounds", OK_Bounds);
         Check ("G-05b rising part is monotone", OK_Monotone);
      end;
   end Test_Gain_Schedule;

   --  D: pitch-rate damper
   --  parameters used by the D tests (raw Q16):
   --    Kq = 2.0 (131_072)   Ki_Dt = 0.01 (655)
   --    Out_Limit = 0.5 (32_768)   Integrator_Limit = 0.1 (6_554)
   --    Rate_Limit = 0.05 per frame (3_277)
   Params : constant Pitch_Rate_Params :=
     (Kq               => 131_072,
      Ki_Dt            => 655,
      Out_Limit        => 32_768,
      Integrator_Limit => 6_554,
      Rate_Limit       => 3_277);

   --  D-01 step response with the rate limiter active, then settling
   --  Input: q_cmd = 0.1 rad/s (6_554), q_meas = 0, valid. Error = 6_554.
   --    P term           = 131_072 * 6_554 / 65_536 = 13_108
   --    integral step    = 655 * 6_554 / 65_536 = 65.5 -> 65 per frame
   --  Frame k: demand = 13_108 + 65 k. The command starts at 0 and may move
   --  by at most 3_277 per frame.
   --    frame 1: demand 13_173, command 3_277      (rate limited)
   --    frame 2: demand 13_238, command 6_554      (rate limited)
   --    frame 3: demand 13_303, command 9_831      (rate limited)
   --    frame 4: demand 13_368, command 13_108     (rate limited)
   --    frame 5: demand 13_433, step 325 <= 3_277 -> command 13_433, nominal
   --  integrator after frame 5 is 5 * 65 = 325.

   procedure Test_Damper_Step_Response is
      S : Damper_State := Initial_State;
      O : Damper_Output;
      Inp : constant Damper_Input :=
        (Q_Cmd => 6_554, Q_Meas => 0, Valid => True);
      Expected : constant array (1 .. 4) of Surface_Cmd :=
        (3_277, 6_554, 9_831, 13_108);
   begin
      for K in Expected'Range loop
         Step (S, Params, Inp, O);
         Check_Q ("D-01 command, frame" & Integer'Image (K),
                  O.Cmd, Expected (K));
         Check ("D-01 rate limited, frame" & Integer'Image (K),
                O.Status = Rate_Limited);
         Check ("D-01 state consistent, frame" & Integer'Image (K),
                Consistent (S, Params));
      end loop;

      Step (S, Params, Inp, O);
      Check_Q ("D-01 command, frame 5", O.Cmd, 13_433);
      Check ("D-01 nominal, frame 5", O.Status = Nominal);
      Check_Q ("D-01 integrator after frame 5", S.Integrator, 325);
      Check ("D-01 hold counter is zero", S.Hold = 0);
   end Test_Damper_Step_Response;

   --  D-02 saturation and anti-windup
   --  Input: q_cmd = 1.0 rad/s (65_536), q_meas = 0. Error = 65_536; P term = 131_072 (2.0), far above the output limit 32_768;
   --  the candidate demand is above the limit and the error is positive, so the integrator is frozen at 0 in every frame

   --  the command climbs by 3_277 per frame: frame k gives 3_277 k while still below the limit; after 9 frames it is 29_493; in frame 10 the remaining step is 3_275 <= 3_277, 
   --  so it reaches 32_768 and the status is Saturated (not Rate_Limited)
   procedure Test_Damper_Windup is
      S : Damper_State := Initial_State;
      O : Damper_Output;
      Inp : constant Damper_Input :=
        (Q_Cmd => 65_536, Q_Meas => 0, Valid => True);
   begin
      for K in 1 .. 9 loop
         Step (S, Params, Inp, O);
         Check_Q ("D-02 command, frame" & Integer'Image (K),
                  O.Cmd, Surface_Cmd (3_277 * K));
         Check ("D-02 rate limited, frame" & Integer'Image (K),
                O.Status = Rate_Limited);
         Check_Q ("D-02 integrator frozen, frame" & Integer'Image (K),
                  S.Integrator, 0);
      end loop;

      Step (S, Params, Inp, O);
      Check_Q ("D-02 command reaches the limit", O.Cmd, 32_768);
      Check ("D-02 saturated at frame 10", O.Status = Saturated);

      Step (S, Params, Inp, O);
      Check_Q ("D-02 command stays at the limit", O.Cmd, 32_768);
      Check ("D-02 still saturated", O.Status = Saturated);
      Check_Q ("D-02 integrator still frozen", S.Integrator, 0);
   end Test_Damper_Windup;

   --  D-03 invalid input: hold, freeze, count, saturate counter, recover
   procedure Test_Damper_Invalid_Input is
      S : Damper_State := Initial_State;
      O : Damper_Output;
      Good : constant Damper_Input :=
        (Q_Cmd => 6_554, Q_Meas => 0, Valid => True);
      Bad  : constant Damper_Input :=
        (Q_Cmd => 524_287, Q_Meas => -524_287, Valid => False);
      Held_Cmd : Surface_Cmd;
      Held_Int : Q16;
   begin
      --  two valid frames: command 6_554, integrator 130 (see D-01)
      Step (S, Params, Good, O);
      Step (S, Params, Good, O);
      Held_Cmd := O.Cmd;
      Held_Int := S.Integrator;
      Check_Q ("D-03a command before the fault", Held_Cmd, 6_554);
      Check_Q ("D-03b integrator before the fault", Held_Int, 130);

      Step (S, Params, Bad, O);
      Check_Q ("D-03c command held", O.Cmd, Held_Cmd);
      Check_Q ("D-03d integrator frozen", S.Integrator, Held_Int);
      Check ("D-03e status is Input_Invalid", O.Status = Input_Invalid);
      Check ("D-03f hold counter is 1", S.Hold = 1);

      --  many more invalid frames: the counter stops at its bound
      for K in 1 .. 30 loop
         Step (S, Params, Bad, O);
      end loop;
      Check ("D-03g hold counter saturates at the bound",
             S.Hold = Hold_Count'Last);
      Check_Q ("D-03h command still held after many frames",
               O.Cmd, Held_Cmd);

      --  A valid frame clears the counter.
      Step (S, Params, Good, O);
      Check ("D-03i hold counter cleared by a valid frame", S.Hold = 0);
      Check ("D-03j status leaves Input_Invalid",
             O.Status /= Input_Invalid);
   end Test_Damper_Invalid_Input;

   --  D-04 sign symmetry: the mirror input gives the mirror output, q_cmd = -0.1 rad/s: P = -13_108, integral step = -65 (truncation toward zero, same magnitude as the 
   --  positive case), command -3_277
   procedure Test_Damper_Symmetry is
      Sp : Damper_State := Initial_State;
      Sn : Damper_State := Initial_State;
      Op : Damper_Output;
      On : Damper_Output;
      Pos : constant Damper_Input :=
        (Q_Cmd => 6_554, Q_Meas => 0, Valid => True);
      Neg_In : constant Damper_Input :=
        (Q_Cmd => -6_554, Q_Meas => 0, Valid => True);
   begin
      for K in 1 .. 8 loop
         Step (Sp, Params, Pos, Op);
         Step (Sn, Params, Neg_In, On);
         Check_Q ("D-04 command mirrors, frame" & Integer'Image (K),
                  On.Cmd, -Op.Cmd);
         Check_Q ("D-04 integrator mirrors, frame" & Integer'Image (K),
                  Sn.Integrator, -Sp.Integrator);
      end loop;
      Check_Q ("D-04 first negative command", -Op.Cmd, On.Cmd);
   end Test_Damper_Symmetry;

   --  D-05 Rebase and Make_Params
   procedure Test_Damper_Config is
      Tight : constant Pitch_Rate_Params :=
        (Kq               => 131_072,
         Ki_Dt            => 655,
         Out_Limit        => 20_000,
         Integrator_Limit => 5_000,
         Rate_Limit       => 3_277);
      S : Damper_State :=
        (Integrator => 6_000, Last_Cmd => 30_000, Hold => 5);
      P : Pitch_Rate_Params;
   begin
      Rebase (S, Tight);
      Check_Q ("D-05a Rebase clamps integrator", S.Integrator, 5_000);
      Check_Q ("D-05b Rebase clamps last command", S.Last_Cmd, 20_000);
      Check ("D-05c Rebase keeps the hold counter", S.Hold = 5);
      Check ("D-05d state consistent after Rebase", Consistent (S, Tight));

      --  a scheduled Kq of zero is raised to the floor (0.10 = 6_554)
      P := Make_Params
        (Gains  => (Kq => 0, Ki_Dt => 100),
         Limits => (Out_Limit => 32_768,
                    Integrator_Limit => 6_554,
                    Rate_Limit => 3_277));
      Check_Q ("D-05e Kq floor applied", P.Kq, Min_Proportional_Gain);
      Check_Q ("D-05f Ki_Dt passed through", P.Ki_Dt, 100);

      --  a scheduled Kq above the floor is kept unchanged
      P := Make_Params
        (Gains  => (Kq => 131_072, Ki_Dt => 100),
         Limits => (Out_Limit => 32_768,
                    Integrator_Limit => 6_554,
                    Rate_Limit => 3_277));
      Check_Q ("D-05g Kq above the floor unchanged", P.Kq, 131_072);
   end Test_Damper_Config;

begin
   Put_Line ("FSAC core tests");

   Test_Numeric;
   Test_Gain_Schedule;
   Test_Damper_Step_Response;
   Test_Damper_Windup;
   Test_Damper_Invalid_Input;
   Test_Damper_Symmetry;
   Test_Damper_Config;

   New_Line;
   Put_Line ("passed:" & Natural'Image (Passed));
   Put_Line ("failed:" & Natural'Image (Failed));

   if Failed > 0 then
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   end if;
end Test_Core;