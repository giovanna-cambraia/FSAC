--  ===========================================================================
--  FSAC - Flight Stability Augmentation Computer
--  ===========================================================================
--  File        : software/core_spark/src/params/fsac-control-params.ads
--  Package     : Fsac.Control.Params
--  Language    : Ada 2012 / SPARK 2014
--  Assurance   : DO-178C Software Level A (target), DO-333 formal supplement
--  SPARK_Mode  : On
--  Requirements: HLR-CTL-0004 .. HLR-CTL-0012 (placeholder IDs)

-- PURPOSE
   -- defines the data the tunes the control laws: gains, limits, and the gain schedule over dynamic pressure, it contains no logic 
   -- that runs in flight; its job is to make an invalid parameter set impossible to construct: every record and table carries a
   -- predicate that states what "valid" means, and the control code can rely on that as a proved fact 

-- WHY PARAMETERS ARE A SAFETY ITEM
   -- on an unstable airframe, a wrong gain is a dangerous as a wrong line of code; gains are produced by the control-law design 
   -- process (MIL, in models/control_laws/), turned into an Ada constant by a code generator (tools/codegen/), and loaded with the
   -- software image; predicates here are the last gate: a parameter set that violates them fails to build or fails the debug-time
   -- predicate check, and is rejected by the loader's consistency test (HLR-CTL-002)

-- TWO PARAMETERS GROUPS
   --  1. Pitch_Rate_Params   (one set per flight condition, see Gain_Schedule)
   --       Kq                Proportional gain on pitch-rate error
   --       Ki_Dt             Integral gain already multiplied by the frame
   --                         period; the integrator then adds Ki_Dt * error
   --                         each frame with no multiplication by dt in flight,
   --                         and the 5 ms period does not need to be
   --                         represented as a rounded Q16 constant
   --       Out_Limit         surface command limit (fraction of full travel),
   --       Integrator_Limit  clamp on the integrator state (its "authority"),
   --       Rate_Limit        largest change of the command per frame
   --                         (the surface rate limit divided by 200 Hz)
   --
   --     Predicate (what "valid" means):
   --       Kq > 0 and Ki_Dt >= 0         negative feedback must exist
   --       Out_Limit > 0                 the law can command something
   --       Rate_Limit > 0                the command can move
   --       Integrator_Limit <= Out_Limit the integrator can never ask for more
   --                                     than the output can deliver
   --       Integrator_Limit <= 30% of full travel
   --                                     HLR-CTL-0005. A runaway integrator
   --                                     then cannot drive the surface hard
   --                                     over on its own
   --
   --  2. Gain_Schedule   (gain as a function of dynamic pressure, in kPa)
   --       eight breakpoints, seven segments between them; for a given
   --       dynamic pressure q in segment i the gain is a linear blend:
   --
   --            t    = (q - Q_Break(i)) * Inv_Span(i)        0.0 .. 1.0
   --            gain = Gain(i) + t * (Gain(i+1) - Gain(i))
   --
   --       because t is between 0 and 1 the result always lies between the two
   --       neighbouring table values: interpolation can not overshoot; the
   --       interpolation itself is written in the next stage
   --       (Fsac.Control.Gain_Schedule), where that property is proved;
   --       below the first breakpoint and above the last, the end values are
   --       used (no extrapolation)
   --
   --       Inv_Span(i) = 1 / (Q_Break(i+1) - Q_Break(i)) is computed offline
   --       and stored, so no division is executed in flight
   --
   --     predicate (what "valid" means):
   --       * breakpoints are at least 1 kPa apart (so they are strictly
   --         increasing, and Inv_Span <= 1.0 fits the Q16 range comfortably)
   --       * each Inv_Span matches its span: the product Span * Inv_Span
   --         differs from 1.0 by at most one least-significant bit of the
   --         stored inverse; a mismatched table is rejected

-- RESOLUTION NOTE
   -- a span of 64 kPa gives Inv_Span about 0.0156 (raw 1024), so t is resolved to roughly 0.1 percent of the segment, for gains that
   -- differ by several units between breakpoints this is well below the effect of sensor noise; the MIL campaign (verification/mil/)
   -- includes a test that compares the quantized schedule with the real-valued design 

-- NOTE ON ARITHMETIC IN THIS FILE 
   -- the predicates compute in Wide because they must be exact; they are evaluated at build and in debug runs (with -gnata) and are
   -- proved by GNATprove, they are not on the flight path 

with Fsac.Types; use Fsac.Types;

package Fsac.Control.Params
   with Pure, SPARK_Mode => On 
is

   -- limits on the parameter values themselves 
   subtype Surface_Limit is Q16 range 0 .. Surface_Cmd_Max_Raw;
   -- non-negative of a surface command or command change 

   Max_Integrator_Authority   : constant Surface_Limit := 19_660;
   -- 0.30 of full travel (0.30 * 6553 = 19660.8, rounded down so the stated limit is never exceeded), HLR-CTL-0005

   -- pitch-rate damper parameters 
    type Pitch_Rate_Params is record
      Kq               : Gain;
      Ki_Dt            : Gain;
      Out_Limit        : Surface_Limit;
      Integrator_Limit : Surface_Limit;
      Rate_Limit       : Surface_Limit;
   end record
     with Dynamic_Predicate =>
       Pitch_Rate_Params.Kq > 0
       and then Pitch_Rate_Params.Out_Limit > 0
       and then Pitch_Rate_Params.Rate_Limit > 0
       and then Pitch_Rate_Params.Integrator_Limit
                  <= Pitch_Rate_Params.Out_Limit
       and then Pitch_Rate_Params.Integrator_Limit
                  <= Max_Integrator_Authority;

   -- gain schedule over dynamic pressure 
   num_points  : constant := 8;

    Num_Points : constant := 8;

   subtype Point_Index   is Positive range 1 .. Num_Points;
   subtype Segment_Index is Positive range 1 .. Num_Points - 1;

   Min_Span_Raw : constant := Q16_One_Raw;
   --  Minimum distance between breakpoints: 1.0 kPa.

   subtype Inverse_Span is Q16 range 1 .. Q16_One_Raw;
   --  1 / span in 1/kPa. At most 1.0 because the span is at least 1 kPa.

   type Pressure_Array is array (Point_Index)   of Dyn_Pressure;
   type Gain_Array     is array (Point_Index)   of Gain;
   type Inverse_Array  is array (Segment_Index) of Inverse_Span;

   type Gain_Schedule is record
      Q_Break  : Pressure_Array;  --  breakpoints, kPa
      Kq       : Gain_Array;      --  proportional gain at each breakpoint
      Ki_Dt    : Gain_Array;      --  integral gain times dt at each breakpoint
      Inv_Span : Inverse_Array;   --  1 / (Q_Break(i+1) - Q_Break(i))
   end record;

   function Span (S : Gain_Schedule; I : Segment_Index) return Wide is
     (Wide (S.Q_Break (I + 1)) - Wide (S.Q_Break (I)))
     with Global => null;
   --  raw distance between breakpoint I and I + 1 (Q16 raw units).

   function Well_Formed (S : Gain_Schedule) return Boolean is
     (for all I in Segment_Index =>
        Span (S, I) >= Wide (Min_Span_Raw)
        and then
          abs (Span (S, I) * Wide (S.Inv_Span (I)) - 4_294_967_296)
            <= Span (S, I))
     with Global => null;
   --  4_294_967_296 is 2**32: the raw value of (1.0 kPa span) * (1.0 /kPa)
   --  after both factors are scaled by 2**16

   subtype Valid_Gain_Schedule is Gain_Schedule
     with Dynamic_Predicate => Well_Formed (Valid_Gain_Schedule);
   --  the only schedule type that the interpolation accepts

end Fsac.Control.Params;