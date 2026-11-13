--  ===========================================================================
--  FSAC - Flight Stability Augmentation Computer
--  ===========================================================================
--  File        : software/core_spark/src/signal_mgmt/fsac-signal_mgmt.ads
--  Package     : Fsac.Signal_Mgmt (parent of all signal-management units)
--  Language    : Ada 2012 / SPARK 2014
--  Assurance   : DO-178C Software Level A (target), DO-333 formal supplement
--  SPARK_Mode  : On
--  Requirements: HLR-SIG-0001 .. HLR-SIG-0004 (placeholder IDs)
--  Decision    : ADR-003 (analytical redundancy as the extra voter)
--
--  PURPOSE
--    Signal management turns several redundant sensors into ONE trusted
--    number for the control law, and says how much it can be trusted. This
--    parent package holds the vocabulary that every unit below it shares:
--    what a reading is, how healthy a sensor is, and how much redundancy is
--    left. The units under it do the work:
--
--        Fsac.Signal_Mgmt.Mid_Value_Select   pick the middle of the usable
--        Fsac.Signal_Mgmt.Cross_Check        find the sensor that disagrees
--        (later) Observer, Voter             analytical channel, final result
--
--  WHERE IT SITS IN THE DATA FLOW (one minor frame)
--
--      C driver sample          Fsac.Platform_Ports        this package tree
--      (per sensor)      -->    To_Rate_Reading     -->    Reading_Set
--                               (Body_Rate + Valid)        |
--                                                          v
--                                          Cross_Check  (health per sensor)
--                                                          |
--                                                          v
--                                          Mid_Value_Select (one value,
--                                                            redundancy level)
--                                                          |
--                                                          v
--                                          Pitch_Rate_Damper (the control law)
--
--  DESIGN PRINCIPLE: VALIDITY IS DECIDED BEFORE VOTING
--    A sensor reaches the voter either usable or not. "Usable" combines two
--    independent opinions:
--      * the bridge says the sample is valid (checked by the C driver and by
--        Fsac.Platform_Ports), and
--      * the health latch has not declared the sensor Failed (found by
--        comparing the sensors with each other over several frames).
--    Voting never has to guess whether a number is believable: it is only
--    given numbers that passed both. That keeps the voter small enough to
--    prove completely.
--
--  Sensor_Health
--    Healthy   agrees with the others
--    Suspect   disagreed recently; still used, because the voter masks one
--              outlier anyway, but watched
--    Failed    disagreed for the full persistence time; EXCLUDED, and the
--              exclusion is latched for the rest of the flight (no automatic
--              return: a sensor that "recovers" mid-flight is more likely a
--              marginal sensor than a good one). Only a maintenance reset
--              on the ground clears it.
--
--  Redundancy_Level
--    Triplex   three usable sensors: one fault can be masked and located
--    Duplex    two usable: a disagreement is DETECTED but cannot be located
--              by sensors alone (the analytical channel breaks the tie)
--    Simplex   one usable: no cross-checking possible
--    Lost      none usable: the control law must hold or revert
--    The ordering Lost < Simplex < Duplex < Triplex is used by the mode
--    logic ("level fell below Duplex").

with Fsac.Types; use Fsac.Types;

package Fsac.Signal_Mgmt
  with Pure, SPARK_Mode => On
is


   --  one measurement and a set of them
   type Reading is record
      Value : Body_Rate;   --  rad/s, meaningful only when Valid
      Valid : Boolean;     --  from the bridge: sample passed every check
   end record;

   type Reading_Set is array (Sensor_Id) of Reading;

   --  health of one sensor
   type Sensor_Health is (Healthy, Suspect, Failed);

   type Health_Set is array (Sensor_Id) of Sensor_Health;

   function Usable (R : Reading; H : Sensor_Health) return Boolean is
     (R.Valid and then H /= Failed)
     with Global => null;

   --  how much redundancy is left
   subtype Usable_Count is Natural range 0 .. Sensors_Per_Measurement;

   type Redundancy_Level is (Lost, Simplex, Duplex, Triplex);

   function To_Level (Count : Usable_Count) return Redundancy_Level is
     (case Count is
        when 0      => Lost,
        when 1      => Simplex,
        when 2      => Duplex,
        when others => Triplex)
     with Global => null;

   pragma Compile_Time_Error
     (Sensors_Per_Measurement /= 3,
      "Redundancy_Level and To_Level assume three sensors per measurement");

end Fsac.Signal_Mgmt;