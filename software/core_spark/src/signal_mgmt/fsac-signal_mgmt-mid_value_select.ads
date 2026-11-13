--  ===========================================================================
--  FSAC - Flight Stability Augmentation Computer
--  ===========================================================================
--  File        : software/core_spark/src/signal_mgmt/fsac-signal_mgmt-mid_value_select.ads
--  Package     : Fsac.Signal_Mgmt.Mid_Value_Select  (specification)
--  Language    : Ada 2012 / SPARK 2014
--  Assurance   : DO-178C Software Level A (target), DO-333 formal supplement
--  SPARK_Mode  : On
--  Requirements: HLR-SIG-0005 .. HLR-SIG-0012 (placeholder IDs)
--
--  PURPOSE
--    Mid-value selection (MVS): from the usable sensors, produce one value
--    that a single faulty sensor cannot drag away. With three usable sensors
--    the result is the MEDIAN. Nothing is averaged, nothing is invented: the
--    answer is one of the three real readings.
--
--  WHY THE MEDIAN MASKS A FAULT (the idea behind the main contract)
--    Call the three readings a <= b <= c. The median is b.
--      * If the faulty sensor is a (reads far too low):  b is still between
--        the two good ones, b and c.
--      * If it is c (far too high):                      b is still between
--        the two good ones, a and b.
--      * If it is b itself (wrong but in the middle):    b lies between a
--        and c, so it cannot be worse than the two good ones.
--    In every case the output is inside the range spanned by the two
--    sensors that are NOT faulty. That statement is the contract below
--    (property M1), and GNATprove proves it for every possible input.
--
--  WHAT HAPPENS WITH FEWER SENSORS
--    Three usable   median            one fault masked and located
--    Two usable     midpoint          disagreement detectable, fault NOT
--                                     locatable (see "Duplex" below)
--    One usable     that reading      no cross-check possible
--    None usable    value 0, level Lost   caller must not use the value
--
--  DUPLEX: THE MIDPOINT IS A DEFAULT, NOT THE FINAL WORD
--    With two usable sensors the midpoint is the neutral, stateless choice:
--    it treats both alike, so it needs no assumption about which is right.
--    But if they disagree strongly, the midpoint is wrong by half the gap.
--    The Voter (later in this part) therefore overrides it when the
--    analytical channel (ADR-003) is available, by taking the sensor that
--    agrees with the model. This package stays simple on purpose.
--
--  PROPERTIES PROVED (GNATprove)
--    M1  With two or more usable sensors, for EVERY pair of usable sensors
--        the result lies between their two values (fault masking).
--    M2  With three usable sensors, the result is exactly one of the three
--        readings (no synthetic value).
--    M3  With one usable sensor, the result is that sensor's reading.
--    M4  With none, the result is 0 and the level is Lost.
--    M5  Count and level always agree with the usable sensors.
--
--  PROPERTY CHECKED BY TESTS (not by proof)
--    M6  A sensor that is NOT usable has no influence: changing its value
--        never changes the result. (This is the leak check: the garbage of
--        a failed sensor cannot reach the control law.)
--
--  TIMING SHAPE
--    No loops. A fixed number of comparisons; the WCET does not depend on
--    the data.

--  no "with Fsac.Types" is needed here: a child unit sees the context of its parent (Fsac.Signal_Mgmt already has "with" and "use" for Fsac.Types)
package Fsac.Signal_Mgmt.Mid_Value_Select
  with SPARK_Mode => On
is

   --  helpers used in the contracts (and available to other units)
   function Within (X, A, B : Body_Rate) return Boolean is
     (X >= Q16'Min (A, B) and then X <= Q16'Max (A, B))
     with Global => null;
   --  X lies in the closed interval spanned by A and B, whichever is larger

   function Count_Usable
     (R : Reading_Set;
      H : Health_Set) return Usable_Count is
     ((if Usable (R (1), H (1)) then 1 else 0)
      + (if Usable (R (2), H (2)) then 1 else 0)
      + (if Usable (R (3), H (3)) then 1 else 0))
     with Global => null;
   --  number of sensors that are valid and not Failed; written out for the three sensors (checked by the compile-time assertion in the parent)

   --  building blocks (public so they can be tested and reused, for example by the cross-lane consensus of the three LRUs)
   function Median3 (A, B, C : Body_Rate) return Body_Rate
     with
       Global => null,
       Post   =>
         (Median3'Result = A or else Median3'Result = B
          or else Median3'Result = C)
         and then Within (Median3'Result, A, B)
         and then Within (Median3'Result, A, C)
         and then Within (Median3'Result, B, C);
   --  the middle one of three values; it lies between every pair

   function Midpoint (A, B : Body_Rate) return Body_Rate
     with
       Global => null,
       Post   => Within (Midpoint'Result, A, B);
   --  (A + B) / 2 with truncation toward zero. Computed in 64 bits, so no overflow is possible. Equal inputs give that same value

   --  the vote
   type Vote_Result is record
      Value : Body_Rate;
      Count : Usable_Count;
      Level : Redundancy_Level;
   end record;

   function Vote
     (R : Reading_Set;
      H : Health_Set) return Vote_Result
     with
       Global => null,
       Post   =>
         --  M5: bookkeeping is consistent
         Vote'Result.Count = Count_Usable (R, H)
         and then Vote'Result.Level = To_Level (Vote'Result.Count)
         --  M4: nothing usable
         and then (if Vote'Result.Count = 0 then Vote'Result.Value = 0)
         --  M3: exactly one usable
         and then
           (if Vote'Result.Count = 1 then
              (for all I in Sensor_Id =>
                 (if Usable (R (I), H (I)) then
                    Vote'Result.Value = R (I).Value)))
         --  M1: for every pair of usable sensors the result is between them
         and then
           (for all I in Sensor_Id =>
              (for all J in Sensor_Id =>
                 (if I < J
                    and then Usable (R (I), H (I))
                    and then Usable (R (J), H (J))
                  then
                    Within (Vote'Result.Value, R (I).Value, R (J).Value))))
         --  M2: with three, the answer is one of the readings
         and then
           (if Vote'Result.Count = 3 then
              Vote'Result.Value = R (1).Value
              or else Vote'Result.Value = R (2).Value
              or else Vote'Result.Value = R (3).Value);

end Fsac.Signal_Mgmt.Mid_Value_Select;