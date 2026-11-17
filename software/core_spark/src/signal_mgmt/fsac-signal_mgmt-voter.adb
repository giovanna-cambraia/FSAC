--  ===========================================================================
--  FSAC - Flight Stability Augmentation Computer
--  ===========================================================================
--  File        : software/core_spark/src/signal_mgmt/fsac-signal_mgmt-voter.adb
--  Package     : Fsac.Signal_Mgmt.Voter  (body)
--  Language    : Ada 2012 / SPARK 2014
--  SPARK_Mode  : On
--
--  PURPOSE
--    Implements Step in the six stages of the specification. Each stage is a
--    short block, in the order of the header, so the code can be read
--    against the description.

package body Fsac.Signal_Mgmt.Voter
  with SPARK_Mode => On
is

   --  The reading of the one usable sensor that is not Out_Id.
   --  Used only in the reference-aided case: exactly two sensors are usable
   --  and Out_Id is one of them.
   function Other_Usable
     (R      : Reading_Set;
      H      : Health_Set;
      Out_Id : Sensor_Id) return Body_Rate
     with
       Global => null,
       Pre    => Usable (R (Out_Id), H (Out_Id))
                 and then Mid_Value_Select.Count_Usable (R, H) = 2,
       Post   =>
         (for some J in Sensor_Id =>
            J /= Out_Id
            and then Usable (R (J), H (J))
            and then Other_Usable'Result = R (J).Value)
   is
   begin
      case Out_Id is
         when 1 =>
            if Usable (R (2), H (2)) then
               return R (2).Value;
            else
               return R (3).Value;
            end if;
         when 2 =>
            if Usable (R (1), H (1)) then
               return R (1).Value;
            else
               return R (3).Value;
            end if;
         when 3 =>
            if Usable (R (1), H (1)) then
               return R (1).Value;
            else
               return R (2).Value;
            end if;
      end case;
   end Other_Usable;

   procedure Step
     (State    : in out Voter_State;
      Params   : Voter_Params;
      R        : Reading_Set;
      Cmd_Prev : Surface_Cmd;
      Output   : out Voted)
   is
      --  Sensors usable BEFORE this frame's update (for the trust rule).
      Count_Before : constant Usable_Count :=
        Mid_Value_Select.Count_Usable (R, Cross_Check.Health_Of (State.Check));

      --  Stage 1: the reference for THIS frame.
      Ref : constant Cross_Check.Reference :=
        (Value => Observer.Predict (State.Obs, Params.Obs, Cmd_Prev),
         Valid => Observer.Reference_Valid (State.Obs, Params.Obs));

      Report : Cross_Check.Check_Report;
   begin
      --  Stage 2: cross-check, health changes take effect now.
      Cross_Check.Update (State.Check, Params.Check, R, Ref, Report);

      declare
         H : constant Health_Set := Cross_Check.Health_Of (State.Check);

         --  Stage 3: the vote on the updated health.
         V : constant Mid_Value_Select.Vote_Result :=
           Mid_Value_Select.Vote (R, H);

         --  Stage 4: reference-aided duplex.
         Aided : constant Boolean :=
           Report.Result = Cross_Check.Located
           and then V.Level = Duplex
           and then Usable (R (Report.Outlier), H (Report.Outlier));

         Value : Body_Rate;
         Level : Redundancy_Level;
      begin
         if Aided then
            Value := Other_Usable (R, H, Report.Outlier);
            Level := Simplex;
         else
            Value := V.Value;
            Level := V.Level;
         end if;

         declare
            --  Stage 5: the trust rule, then feed the observer.
            Trusted : constant Boolean :=
              (Count_Before = 3
               and then (Report.Result = Cross_Check.All_Agree
                         or else Report.Result = Cross_Check.Located))
              or else
                (Count_Before = 2
                 and then Report.Result = Cross_Check.All_Agree);
         begin
            Observer.Update
              (State.Obs, Params.Obs, Cmd_Prev, Value, Trusted);

            --  Stage 6: publish.
            Output :=
              (Value   => Value,
               Level   => Level,
               Valid   => Level /= Lost,
               Trusted => Trusted,
               Aided   => Aided,
               Check   => Report);
         end;
      end;
   end Step;

end Fsac.Signal_Mgmt.Voter;