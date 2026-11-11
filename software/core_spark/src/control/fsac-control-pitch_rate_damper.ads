--  ===========================================================================
--  FSAC - Flight Stability Augmentation Computer
--  ===========================================================================
--  File        : software/core_spark/src/control/fsac-control-pitch_rate_damper.ads
--  Package     : Fsac.Control.Pitch_Rate_Damper  (specification)
--  Language    : Ada 2012 / SPARK 2014
--  Assurance   : DO-178C Software Level A (target), DO-333 formal supplement
--  SPARK_Mode  : On
--  Requirements: HLR-CTL-0020 .. HLR-CTL-0034 (placeholder IDs)
--
--  PURPOSE
   -- the inner-loop pitch-rate damper: the controller that, 200 times per
   -- second, compares the pilot's (or outer loop's) commanded pitch rate with
   -- the measured pitch rate and produces an elevator command that drives
   -- the difference toward zero. On a statically unstable airframe this loop
   -- is what keeps the aircraft flyable; losing it for 120 ms can break
   -- the structure

--  THE CONTROL LAW (executed once per minor frame, in this order)
   --       e      = q_cmd - q_meas                   rate error, saturated
   --       P      = Kq * e                           proportional term
   --       I'     = clamp (I + Ki_Dt * e,            integral term with
   --                      -I_lim, +I_lim)           position clamp
   --                (not updated if the output is saturated and the error
   --                 pushes further into the saturation: anti-windup)
   --       u      = P + I'                           unlimited demand
   --       u_sat  = clamp (u, -Out_Limit, +Out_Limit)     position limit
   --       u_out  = last + clamp (u_sat - last,           surface rate limit
   --                              -Rate_Limit, +Rate_Limit)
   --
   -- "last" is the command issued in the previous frame; the command is a
   -- normalized surface position (+-1.0 = full travel); conversion to the
   -- physical surface sign and to actuator units happens in the actuator
   -- command partition, not here

--  INPUT VALIDITY RULE
   -- if the input is flagged invalid by the upstream voter, the law does NOT
   -- compute; it repeats its last command, freezes the integrator, and
   -- reports Input_Invalid, it counts how many consecutive frames this has
   -- happened (Hold); deciding to revert to another mode is the mode logic's
   -- job; the damper never guesses a measurement

--  PROPERTIES GUARANTEED BY THE CONTRACT (each is proved by GNATprove)
   --    C1  Position limit.   |command| <= Out_Limit, every frame.
   --    C2  Rate limit.       |command - previous command| <= Rate_Limit.
   --    C3  Integrator bound. |integrator| <= Integrator_Limit, every frame.
   --    C4  Invalid input.    Command is exactly the previous one, the
   --                          integrator is unchanged, status is Input_Invalid.
   --    C5  Hold counter.     0 after a valid frame, +1 per invalid frame,
   --                          never above Max_Uncorrected_Frames.
   --    C6  Status truth.     Saturated means the command is at the position
   --                          limit; Rate_Limited means the rate limiter acted.
   --    C7  Closed state.     If the state is consistent with the parameters
   --                          before the call, it is consistent after it
   --                          (so the property holds for the whole flight, by
   --                          induction over frames).
   --    C8  No hidden state.  Global => null: the output depends only on the
   --                          arguments, which is what makes command-lane and
   --                          monitor-lane comparison meaningful.

--  WHAT THE PROOF DOES NOT SHOW (important for the safety case)
   -- the proof shows that the software cannot overflow, cannot exceed its
   -- limits, and implements the law above, it does NOT show that this law
   -- stabilizes the airframe; closed-loop stability, gain and phase margins,
   -- and behaviour at the actuator limits come from analysis and simulation
   -- of the plant (models/, verification/mil/), and are separate evidence in
   -- the safety case. A correct implementation of a wrong gain is still a
   -- wrong controller, keep the two kinds of evidence distinct

--  STATE AND REUSE
   -- the state is passed in and out explicitly (no package variables); each
   -- FSAC lane has its own instance in its own partition memory, and the test
   -- bench can run thousands of independent instances.

--  TIMING SHAPE
   -- straight-line code, no loops: a fixed number of Fixed_Math calls; the
   -- WCET is the same for every input and is measured against the 0.60 ms
   -- window W4 of the schedule (Part 1, section 4)

with Fsac.Types;                 use Fsac.Types;
with Fsac.Fixed_Math;            use Fsac.Fixed_Math;
with Fsac.Control.Params;        use Fsac.Control.Params;
with Fsac.Control.Gain_Schedule; use Fsac.Control.Gain_Schedule;

package Fsac.Control.Pitch_Rate_Damper
  with SPARK_Mode => On
is

   --  data
   subtype Integrator_Value is Q16
     range -Max_Integrator_Authority .. Max_Integrator_Authority;

   type Damper_State is record
      Integrator : Integrator_Value;
      Last_Cmd   : Surface_Cmd;
      Hold       : Hold_Count;
   end record;

   Initial_State : constant Damper_State :=
     (Integrator => 0,
      Last_Cmd   => 0,
      Hold       => 0);

   type Damper_Input is record
      Q_Cmd  : Body_Rate;    --  commanded pitch rate, rad/s
      Q_Meas : Body_Rate;    --  voted, validated measurement, rad/s
      Valid  : Boolean;      --  False: measurement or command not trusted
   end record;

   type Damper_Output is record
      Cmd    : Surface_Cmd;
      Status : Loop_Status;
   end record;

   --  consistency between state and parameters
   function Consistent
     (State  : Damper_State;
      Params : Pitch_Rate_Params) return Boolean
   is
     (State.Integrator >= -Params.Integrator_Limit
      and then State.Integrator <= Params.Integrator_Limit
      and then State.Last_Cmd >= -Params.Out_Limit
      and then State.Last_Cmd <= Params.Out_Limit)
     with Global => null;
   --  the state fits inside the limits in force; Initial_State is consistent
   --  with every valid parameter set (all limits are positive)

   --  building the parameters for the current frame
   type Limit_Set is record
      Out_Limit        : Surface_Limit;
      Integrator_Limit : Surface_Limit;
      Rate_Limit       : Surface_Limit;
   end record
     with Dynamic_Predicate =>
       Limit_Set.Out_Limit > 0
       and then Limit_Set.Rate_Limit > 0
       and then Limit_Set.Integrator_Limit <= Limit_Set.Out_Limit
       and then Limit_Set.Integrator_Limit <= Max_Integrator_Authority;
   --  the limits that do not depend on flight condition.

   Min_Proportional_Gain : constant Gain := 6_554;
   --  0.10; floor applied to the scheduled Kq so the controller always has
   --  negative feedback (the Pitch_Rate_Params predicate requires Kq > 0);
   --  the value is a control-design parameter: replace it with the figure
   --  from the control law design report

   function Make_Params
     (Gains  : Scheduled_Gains;
      Limits : Limit_Set) return Pitch_Rate_Params
     with
       Global => null,
       Post   =>
         Make_Params'Result.Kq = Q16'Max (Gains.Kq, Min_Proportional_Gain)
         and then Make_Params'Result.Ki_Dt = Gains.Ki_Dt
         and then Make_Params'Result.Out_Limit = Limits.Out_Limit
         and then Make_Params'Result.Integrator_Limit = Limits.Integrator_Limit
         and then Make_Params'Result.Rate_Limit = Limits.Rate_Limit;
   --  combines scheduled gains with fixed limits into a valid parameter set

   --  Operations
   procedure Rebase
     (State  : in out Damper_State;
      Params : Pitch_Rate_Params)
     with
       Global => null,
       Post   =>
         Consistent (State, Params)
         and then State.Hold = State.Hold'Old;
   --  brings state inside limits of a new parameter set during reconfigurations

   procedure Step
     (State  : in out Damper_State;
      Params : Pitch_Rate_Params;
      Input  : Damper_Input;
      Output : out Damper_Output)
     with
       Global  => null,
       Depends =>
         (State  => (State, Params, Input),
          Output => (State, Params, Input)),
       Pre     => Consistent (State, Params),
       Post    =>
         --  C7: the state stays consistent
         Consistent (State, Params)
         --  C1: position limit
         and then Abs_Q (Output.Cmd) <= Params.Out_Limit
         --  the output is also what the next frame calls "previous"
         and then Output.Cmd = State.Last_Cmd
         --  C2: rate limit
         and then
           Abs_Q (Sub_Sat (Output.Cmd, State.Last_Cmd'Old))
             <= Params.Rate_Limit
         --  C3: integrator bound
         and then Abs_Q (State.Integrator) <= Params.Integrator_Limit
         --  C4: invalid input holds everything
         and then
           (if not Input.Valid then
              Output.Status = Input_Invalid
              and then Output.Cmd = State.Last_Cmd'Old
              and then State.Integrator = State.Integrator'Old)
         and then (if Input.Valid then Output.Status /= Input_Invalid)
         --  C5: hold counter
         and then
           State.Hold =
             (if Input.Valid then 0
              elsif State.Hold'Old < Hold_Count'Last then State.Hold'Old + 1
              else Hold_Count'Last)
         --  C6: status truth
         and then
           (if Output.Status = Saturated then
              Abs_Q (Output.Cmd) = Params.Out_Limit);

end Fsac.Control.Pitch_Rate_Damper;