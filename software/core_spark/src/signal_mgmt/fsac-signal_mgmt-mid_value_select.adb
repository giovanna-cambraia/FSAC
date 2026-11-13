--  ===========================================================================
--  FSAC - Flight Stability Augmentation Computer
--  ===========================================================================
--  File        : software/core_spark/src/signal_mgmt/fsac-signal_mgmt-mid_value_select.adb
--  Package     : Fsac.Signal_Mgmt.Mid_Value_Select  (body)
--  Language    : Ada 2012 / SPARK 2014
--  SPARK_Mode  : On
--
--  PURPOSE
--    Implements Median3, Midpoint and Vote. Vote only decides WHICH sensors
--    take part (by the usable flags), then calls the right building block.
--    No loops, no recursion, no allocation.
--
--  READING THE CODE AGAINST THE CONTRACT
--    Median3  six cases, one per ordering of A, B, C. The comment on each
--             return states the ordering that selects it.
--    Midpoint sum in 64 bits then halve; the result is between A and B by
--             arithmetic (truncation toward zero never crosses either end).
--    Vote     the first matching case of "which sensors are usable" decides:
--             all three, then the three pairs, then the three singles, then
--             none.

package body Fsac.Signal_Mgmt.Mid_Value_Select
  with SPARK_Mode => On
is

   function Median3 (A, B, C : Body_Rate) return Body_Rate is
   begin
      if A <= B then
         if B <= C then
            return B;            --  A <= B <= C
         elsif A <= C then
            return C;            --  A <= C < B
         else
            return A;            --  C < A <= B
         end if;
      else
         if A <= C then
            return A;            --  B < A <= C
         elsif B <= C then
            return C;            --  B <= C < A
         else
            return B;            --  C < B < A
         end if;
      end if;
   end Median3;

   function Midpoint (A, B : Body_Rate) return Body_Rate is
   begin
      return Body_Rate ((Wide (A) + Wide (B)) / 2);
   end Midpoint;

   function Vote
     (R : Reading_Set;
      H : Health_Set) return Vote_Result
   is
      U1 : constant Boolean := Usable (R (1), H (1));
      U2 : constant Boolean := Usable (R (2), H (2));
      U3 : constant Boolean := Usable (R (3), H (3));

      N  : constant Usable_Count := Count_Usable (R, H);

      Chosen : Body_Rate;
   begin
      if U1 and then U2 and then U3 then
         Chosen := Median3 (R (1).Value, R (2).Value, R (3).Value);
      elsif U1 and then U2 then
         Chosen := Midpoint (R (1).Value, R (2).Value);
      elsif U1 and then U3 then
         Chosen := Midpoint (R (1).Value, R (3).Value);
      elsif U2 and then U3 then
         Chosen := Midpoint (R (2).Value, R (3).Value);
      elsif U1 then
         Chosen := R (1).Value;
      elsif U2 then
         Chosen := R (2).Value;
      elsif U3 then
         Chosen := R (3).Value;
      else
         Chosen := 0;
      end if;

      return (Value => Chosen, Count => N, Level => To_Level (N));
   end Vote;

end Fsac.Signal_Mgmt.Mid_Value_Select;