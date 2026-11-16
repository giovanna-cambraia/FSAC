--  ===========================================================================
--  FSAC - Flight Stability Augmentation Computer
--  ===========================================================================
--  File        : software/core_spark/src/signal_mgmt/fsac-signal_mgmt-observer.adb
--  Package     : Fsac.Signal_Mgmt.Observer  (body)
--  Language    : Ada 2012 / SPARK 2014
--  SPARK_Mode  : On
--
--  PURPOSE
--    Implements Predict and Update. All arithmetic goes through
--    Fsac.Fixed_Math (saturating, proved), so no overflow is possible.
--
--  READING THE CODE AGAINST THE SPECIFICATION
--    Predict   P = A * estimate + B * command, saturated, then clamped to
--              the Body_Rate range.
--    Update    trusted: correction L * (m - P) added to P, then CLAMPED
--              between P and m so the result can never overshoot the
--              measurement (property O1).
--              not trusted: the prediction becomes the estimate, the age
--              grows (property O2).

with Fsac.Fixed_Math; use Fsac.Fixed_Math;

package body Fsac.Signal_Mgmt.Observer
  with SPARK_Mode => On
is

   function Predict
     (S   : Observer_State;
      P   : Observer_Params;
      Cmd : Surface_Cmd) return Body_Rate
   is
   begin
      return To_Body_Rate
        (Add_Sat (Mul_Q (P.A, S.Estimate), Mul_Q (P.B, Cmd)));
   end Predict;

   procedure Update
     (S       : in out Observer_State;
      P       : Observer_Params;
      Cmd     : Surface_Cmd;
      Meas    : Body_Rate;
      Trusted : Boolean)
   is
      Pred : constant Body_Rate := Predict (S, P, Cmd);
   begin
      if Trusted then
         declare
            Innovation : constant Q16 := Sub_Sat (Meas, Pred);
            Correction : constant Q16 := Mul_Q (P.L, Innovation);
            Raw        : constant Q16 := Add_Sat (Pred, Correction);
            Corrected  : constant Body_Rate :=
              Clamp (Raw, Q16'Min (Pred, Meas), Q16'Max (Pred, Meas));
         begin
            S := (Estimate    => Corrected,
                  Age         => 0,
                  Initialized => True);
         end;
      else
         S.Estimate := Pred;

         if S.Age < Age_Frames'Last then
            S.Age := S.Age + 1;
         end if;
      end if;
   end Update;

end Fsac.Signal_Mgmt.Observer;