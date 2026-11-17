--  ===========================================================================
--  FSAC - Flight Stability Augmentation Computer
--  ===========================================================================
--  File        : software/core_spark/src/modes/fsac-modes.adb
--  Package     : Fsac.Modes  (body)
--  Language    : Ada 2012 / SPARK 2014
--  SPARK_Mode  : On
--
--  PURPOSE
--    Implements Update (counters, then demand, then the one-way latch),
--    Reset and Scaled_Params. All scaling arithmetic goes through
--    Fsac.Fixed_Math, so nothing can overflow.

with Fsac.Fixed_Math; use Fsac.Fixed_Math;

package body Fsac.Modes
  with SPARK_Mode => On
is

   procedure Update
     (State : in out Mode_State;
      I     : Mode_Inputs)
   is
      Unresolved : constant Frame_Run :=
        Next_Run (State.Unresolved_Frames,
                  I.Check_Result = Signal_Mgmt.Cross_Check.Unresolved);
      Saturated  : constant Frame_Run :=
        Next_Run (State.Saturated_Frames,
                  I.Loop_Status = Control.Saturated);
      Lost       : constant Frame_Run :=
        Next_Run (State.Lost_Frames,
                  I.Level = Signal_Mgmt.Lost);

      Wanted : constant Mode := Demand (Unresolved, Saturated, Lost, I);
   begin
      State.Unresolved_Frames := Unresolved;
      State.Saturated_Frames  := Saturated;
      State.Lost_Frames       := Lost;

      --  The latch: never better than before.
      State.Current := Mode'Max (State.Current, Wanted);
   end Update;

   procedure Reset (State : out Mode_State) is
   begin
      State := Initial_State;
   end Reset;

   function Scaled_Params
     (Base : Control.Params.Pitch_Rate_Params;
      P    : Mode_Profile) return Control.Params.Pitch_Rate_Params
   is
      use Control.Params;

      --  Gains: scaled, floored at Gain_Floor, never above the base value.
      Kq : constant Gain :=
        Q16'Min (Base.Kq,
                 Q16'Max (Mul_Q (Base.Kq, P.Gain_Scale), Gain_Floor));

      Ki_Dt : constant Gain :=
        Q16'Min (Base.Ki_Dt, Mul_Q (Base.Ki_Dt, P.Gain_Scale));

      --  Limits: scaled, at least 1, never above the base value.
      Out_Limit : constant Surface_Limit :=
        Q16'Min (Base.Out_Limit,
                 Q16'Max (Mul_Q (Base.Out_Limit, P.Limit_Scale), 1));

      Rate_Limit : constant Surface_Limit :=
        Q16'Min (Base.Rate_Limit,
                 Q16'Max (Mul_Q (Base.Rate_Limit, P.Limit_Scale), 1));

      --  The integrator may not ask for more than the output can deliver.
      Integrator_Limit : constant Surface_Limit :=
        Q16'Min (Base.Integrator_Limit, Out_Limit);
   begin
      return (Kq               => Kq,
              Ki_Dt            => Ki_Dt,
              Out_Limit        => Out_Limit,
              Integrator_Limit => Integrator_Limit,
              Rate_Limit       => Rate_Limit);
   end Scaled_Params;

end Fsac.Modes;