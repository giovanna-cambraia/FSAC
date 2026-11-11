--  ===========================================================================
--  FSAC - Flight Stability Augmentation Computer
--  ===========================================================================
--  File        : software/core_spark/src/control/fsac-control-pitch_rate_damper.adb
--  Package     : Fsac.Control.Pitch_Rate_Damper  (body)
--  Language    : Ada 2012 / SPARK 2014
--  Assurance   : DO-178C Software Level A (target), DO-333 formal supplement
--  SPARK_Mode  : On
--  Requirements: HLR-CTL-0020 .. HLR-CTL-0034 (placeholder IDs)

--  PURPOSE
   -- implements the contracts of fsac-control-pitch_rate_damper.ads; the code follows the law in the specification header step by step; each step is one named constant, so a 
   -- reviewer can read the body against the equations line by line

--  STRUCTURE OF Step
   -- Invalid input  : repeat the previous command, freeze the integrator, count the frame. No arithmetic on the measurement
   -- Valid input    : error -> P term -> candidate integrator -> anti-windup test -> demand -> position limit -> rate limit -> status -> new state

--  ANTI-WINDUP, IN WORDS
   -- the integrator accumulates error, if the output is already at its limit and the error would push it further in the same direction, more accumulation only stores a debt 
   -- that must be paid back later, with an overshoot; so in that situation the integrator is frozen at its previous value, it is still clamped to its authority limit in every
   -- case, which is what the contract proves (C3)

--  WHAT GNATPROVE MUST SHOW HERE
   --    Item                             Expected result
   --    -------------------------------  -------------------------------------
   --    Make_Params predicate on result  proved: Kq >= 0.10, limits from Limits
   --    Rebase Post                      proved from the Clamp postconditions
   --    Step: all Pre of Clamp           proved: limits are non-negative
   --    Step: integrator range checks    proved: Clamp bound and frozen value
   --    Step C1, C2 (position, rate)     proved by LINEAR arithmetic, but only
   --                                     with the exact-value assertions below
   --    Step C4, C5 (invalid input)      proved, straight assignments
   --    Step C6 (status truth)           proved from the branch conditions

--  WHERE TROUBLE IS MOST LIKELY
   -- the rate-limit argument (C2) needs the prover to know that Sub_Sat and Add_Sat did not saturate there; they did not, because every operand is at most 1.0 in magnitude, 
   -- so sums and differences stay below 3.0 (raw 196 608), far inside the Q16 range; the assertions marked HINT state those exact equalities, if the prover still fails:
   --      1. run with --level=3 on this unit,
   --      2. check which HINT assertion is reported unproved: that is the
   --         fact it cannot see,
   --      3. as a last resort, replace the failing Saturate-based equality by
   --         an explicit range lemma in Fsac.Fixed_Math.

--  WHY THE NUMBERS NEVER SATURATE IN THE POSITION/RATE STAGE
   -- Prev and U_Sat both lie in [-1.0, +1.0]; Step_Req = U_Sat - Prev lies in [-2.0, +2.0]. Prev + Step_Lim lies between Prev and U_Sat (the rate limiter only shortens the 
   -- step,  never lengthens or reverses it), so it is again inside [-Out_Limit, +Out_Limit]; the P and I terms before that point may saturate (Gain 16.0 times error 16.0 is 
   -- 256.0, which fits, but sums can grow); that is harmless because the next operation is the position limit

package body Fsac.Control.Pitch_Rate_Damper
  with SPARK_Mode => On
is

   --  Make_Params
   function Make_Params
     (Gains  : Scheduled_Gains;
      Limits : Limit_Set) return Pitch_Rate_Params
   is
   begin
      return
        (Kq               => Q16'Max (Gains.Kq, Min_Proportional_Gain),
         Ki_Dt            => Gains.Ki_Dt,
         Out_Limit        => Limits.Out_Limit,
         Integrator_Limit => Limits.Integrator_Limit,
         Rate_Limit       => Limits.Rate_Limit);
   end Make_Params;

   --  Rebase
   procedure Rebase
     (State  : in out Damper_State;
      Params : Pitch_Rate_Params)
   is
   begin
      State.Integrator :=
        Clamp
          (State.Integrator,
           Neg (Params.Integrator_Limit),
           Params.Integrator_Limit);

      State.Last_Cmd :=
        Clamp
          (State.Last_Cmd,
           Neg (Params.Out_Limit),
           Params.Out_Limit);
   end Rebase;

   --  Step
   procedure Step
     (State  : in out Damper_State;
      Params : Pitch_Rate_Params;
      Input  : Damper_Input;
      Output : out Damper_Output)
   is
      Prev : constant Surface_Cmd := State.Last_Cmd;
   begin
      if not Input.Valid then

         --  invalid input: hold, do not compute (C4, C5)
         Output := (Cmd => Prev, Status => Input_Invalid);

         if State.Hold < Hold_Count'Last then
            State.Hold := State.Hold + 1;
         end if;

      else

         --  valid input: the control law
         declare
            Out_Lim : constant Q16 := Params.Out_Limit;
            Neg_Out : constant Q16 := Neg (Params.Out_Limit);

            --  e = q_cmd - q_meas
            Err : constant Rate_Error :=
              To_Rate_Error (Sub_Sat (Input.Q_Cmd, Input.Q_Meas));

            --  P = Kq * e
            P_Term : constant Q16 := Mul_Q (Params.Kq, Err);

            --  candidate integrator, clamped to its authority
            I_Step : constant Q16 := Mul_Q (Params.Ki_Dt, Err);
            I_Cand : constant Q16 :=
              Clamp
                (Add_Sat (State.Integrator, I_Step),
                 Neg (Params.Integrator_Limit),
                 Params.Integrator_Limit);

            --  what the output would be if the integrator were updated
            Demand_Cand : constant Q16 := Add_Sat (P_Term, I_Cand);

            --  anti-windup: freeze when saturated and the error pushes on
            Windup : constant Boolean :=
              (Demand_Cand > Out_Lim and then Err > 0)
              or else (Demand_Cand < Neg_Out and then Err < 0);

            Int_New : constant Q16 :=
              (if Windup then State.Integrator else I_Cand);

            --  u = P + I'
            Demand : constant Q16 := Add_Sat (P_Term, Int_New);

            --  position limit
            U_Sat : constant Q16 := Clamp (Demand, Neg_Out, Out_Lim);

            --  surface rate limit
            Step_Req : constant Q16 := Sub_Sat (U_Sat, Prev);
            Step_Lim : constant Q16 :=
              Clamp (Step_Req, Neg (Params.Rate_Limit), Params.Rate_Limit);
            U_Out    : constant Q16 := Add_Sat (Prev, Step_Lim);
         begin
            --  HINT: no saturation in the position/rate stage; all operands are within one full travel, so these sums and differences are exact
            pragma Assert
              (Wide (Step_Req) = Wide (U_Sat) - Wide (Prev));
            pragma Assert
              (Wide (U_Out) = Wide (Prev) + Wide (Step_Lim));

            --  the rate limiter only shortens the step, so the result lies between Prev and U_Sat, both inside the position limit
            pragma Assert (U_Out >= Neg_Out);
            pragma Assert (U_Out <= Out_Lim);

            --  HINT for C2: the applied step is exactly the limited step
            pragma Assert (Sub_Sat (U_Out, Prev) = Step_Lim);

            declare
               Cmd_Out : constant Surface_Cmd := U_Out;

               Status : constant Loop_Status :=
                 (if U_Out /= U_Sat then Rate_Limited
                  elsif Demand > Out_Lim or else Demand < Neg_Out
                  then Saturated
                  else Nominal);
            begin
               State  := (Integrator => Int_New,
                          Last_Cmd   => Cmd_Out,
                          Hold       => 0);
               Output := (Cmd => Cmd_Out, Status => Status);
            end;
         end;

      end if;
   end Step;

end Fsac.Control.Pitch_Rate_Damper;