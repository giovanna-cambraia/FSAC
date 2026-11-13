--  ===========================================================================
--  FSAC - Flight Stability Augmentation Computer
--  ===========================================================================
--  File        : software/platform_bridge/fsac-platform_ports.adb
--  Package     : Fsac.Platform_Ports  (body)
--  Language    : Ada 2012 / SPARK 2014
--  SPARK_Mode  : On
--
--  PURPOSE
--    Implements To_Rate_Reading. The decision table is Classify in the
--    specification, so this body only builds the result from its answer.
--    That keeps one definition of "what is accepted": the specification.
--
--  WHAT GNATPROVE MUST SHOW HERE
--    * The conversion Body_Rate (S.Value) cannot fail its range check:
--      it is only reached when Classify returned Accepted, which implies
--      Value is inside the Body_Rate range (the prover unfolds Classify,
--      an expression function in the specification).
--    * Every Post of To_Rate_Reading, which restate the table above.

package body Fsac.Platform_Ports
  with SPARK_Mode => On
is

   function To_Rate_Reading (S : Sensor_Sample) return Rate_Reading is
      Why : constant Reject_Reason := Classify (S);
   begin
      if Why = Accepted then
         return (Value         => Body_Rate (S.Value),
                 Valid         => True,
                 Reason        => Accepted,
                 Driver_Status => S.Status);
      else
         return (Value         => 0,
                 Valid         => False,
                 Reason        => Why,
                 Driver_Status => S.Status);
      end if;
   end To_Rate_Reading;

end Fsac.Platform_Ports;