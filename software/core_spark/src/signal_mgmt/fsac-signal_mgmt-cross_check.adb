--  ===========================================================================
--  FSAC - Flight Stability Augmentation Computer
--  ===========================================================================
--  File        : software/core_spark/src/signal_mgmt/fsac-signal_mgmt-cross_check.adb
--  Package     : Fsac.Signal_Mgmt.Cross_Check  (body)
--  Language    : Ada 2012 / SPARK 2014
--  SPARK_Mode  : On
--
--  PURPOSE
--    Implements Update in the two phases of the specification:
--      Phase A  decide: which sensors take part, who agrees, who is the
--               outlier (the Decision and the Outlier). Reads only.
--      Phase B  apply: move each sensor's counter and health by the
--               decision. One helper, Step_One, called for each sensor, so
--               the rules for a single sensor are written once.
--
--  Step_One RULES (per sensor)
--    Failed                          unchanged (latched)
--    not usable this frame           unchanged (no evidence about it)
--    Insufficient or Unresolved      unchanged (no evidence)
--    All_Agree                       count down by 1, minimum 0
--    Located, and this is the outlier   count up by 1
--    Located, and this is not the outlier   count down by 1, minimum 0
--    then health from the count: 0 Healthy, below the limit Suspect,
--    at the limit Failed.

package body Fsac.Signal_Mgmt.Cross_Check
  with SPARK_Mode => On
is

   --  phase B helper: one sensor

   procedure Step_One
     (S           : in out Sensor_State;
      Is_Usable   : Boolean;
      Result      : Decision;
      Is_Outlier  : Boolean;
      Persistence : Persistence_Frames)
     with
       Global => null,
       Pre    => Consistent_One (S, Persistence),
       Post   =>
         Consistent_One (S, Persistence)
         and then (if S'Old.Health = Failed then S.Health = Failed)
         and then
           (if S'Old.Health /= Failed and then S.Health = Failed then
              Is_Usable
              and then Result = Located
              and then Is_Outlier
              and then S.Count = Persistence)
         and then
           ((not Is_Usable) or else Result = Insufficient
            or else Result = Unresolved or else S'Old.Health = Failed)
           <= (S = S'Old)
   is
      Count : Disagree_Count := S.Count;
   begin
      if S.Health = Failed or else not Is_Usable then
         null;   --  latched, or no evidence about this sensor
      else
         case Result is
            when Insufficient | Unresolved =>
               null;

            when All_Agree =>
               if Count > 0 then
                  Count := Count - 1;
               end if;

            when Located =>
               if Is_Outlier then
                  --  consistent_One gives Count < Persistence, so Count + 1 stays inside Disagree_Count
                  Count := Count + 1;
               elsif Count > 0 then
                  Count := Count - 1;
               end if;
         end case;

         S.Count := Count;

         if Count >= Persistence then
            S.Health := Failed;
         elsif Count = 0 then
            S.Health := Healthy;
         else
            S.Health := Suspect;
         end if;
      end if;
   end Step_One;

   --  Update

   procedure Update
     (State  : in out Check_State;
      Params : Check_Params;
      R      : Reading_Set;
      Ref    : Reference;
      Report : out Check_Report)
   is
      Old : constant Check_State := State;

      T  : constant Rate_Threshold := Params.Threshold;

      U1 : constant Boolean := Usable (R (1), Old (1).Health);
      U2 : constant Boolean := Usable (R (2), Old (2).Health);
      U3 : constant Boolean := Usable (R (3), Old (3).Health);

      V1 : constant Body_Rate := R (1).Value;
      V2 : constant Body_Rate := R (2).Value;
      V3 : constant Body_Rate := R (3).Value;

      Dec : Decision;
      Out_Id : Sensor_Id := 1;

      --  two usable sensors I and J (values A and B): decide.
      procedure Decide_Pair
        (Id_A : Sensor_Id; A : Body_Rate;
         Id_B : Sensor_Id; B : Body_Rate)
        with
          Global => (Input  => (T, Ref),
                     Output => Dec,
                     In_Out => Out_Id),
          Pre    => Id_A /= Id_B,
          Post   =>
            (Dec = All_Agree or else Dec = Located or else Dec = Unresolved)
            and then
              (if Dec = All_Agree then not Differ (A, B, T))
            and then
              (if Dec = Located then
                 Differ (A, B, T)
                 and then (Out_Id = Id_A or else Out_Id = Id_B))
      is
         Close_A : Boolean;
         Close_B : Boolean;
      begin
         if not Differ (A, B, T) then
            Dec := All_Agree;
         elsif Ref.Valid then
            Close_A := not Differ (A, Ref.Value, T);
            Close_B := not Differ (B, Ref.Value, T);
            if Close_B and then not Close_A then
               Dec := Located;
               Out_Id := Id_A;
            elsif Close_A and then not Close_B then
               Dec := Located;
               Out_Id := Id_B;
            else
               Dec := Unresolved;
            end if;
         else
            Dec := Unresolved;
         end if;
      end Decide_Pair;

   begin
      --  phase A: decide
      if U1 and then U2 and then U3 then
         declare
            A12 : constant Boolean := not Differ (V1, V2, T);
            A13 : constant Boolean := not Differ (V1, V3, T);
            A23 : constant Boolean := not Differ (V2, V3, T);
         begin
            if A12 and then A13 and then A23 then
               Dec := All_Agree;
            elsif A23 and then not A12 and then not A13 then
               Dec := Located;
               Out_Id := 1;
            elsif A13 and then not A12 and then not A23 then
               Dec := Located;
               Out_Id := 2;
            elsif A12 and then not A13 and then not A23 then
               Dec := Located;
               Out_Id := 3;
            else
               Dec := Unresolved;
            end if;
         end;
      elsif U1 and then U2 then
         Decide_Pair (1, V1, 2, V2);
      elsif U1 and then U3 then
         Decide_Pair (1, V1, 3, V3);
      elsif U2 and then U3 then
         Decide_Pair (2, V2, 3, V3);
      else
         Dec := Insufficient;
      end if;

      --  phase B: apply
      Step_One (State (1), U1, Dec, Dec = Located and then Out_Id = 1, Params.Persistence);
      Step_One (State (2), U2, Dec, Dec = Located and then Out_Id = 2, Params.Persistence);
      Step_One (State (3), U3, Dec, Dec = Located and then Out_Id = 3, Params.Persistence);

      Report :=
        (Result       => Dec,
         Outlier      => Out_Id,
         Newly_Failed =>
           (Old (1).Health /= Failed and then State (1).Health = Failed)
           or else (Old (2).Health /= Failed and then State (2).Health = Failed)
           or else (Old (3).Health /= Failed and then State (3).Health = Failed));
   end Update;

end Fsac.Signal_Mgmt.Cross_Check;