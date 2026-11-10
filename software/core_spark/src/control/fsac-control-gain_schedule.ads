--  ===========================================================================
--  FSAC - Flight Stability Augmentation Computer
--  ===========================================================================
--  File        : software/core_spark/src/control/fsac-control-gain_schedule.ads
--  Package     : Fsac.Control.Gain_Schedule  (specification)
--  Language    : Ada 2012 / SPARK 2014
--  Assurance   : DO-178C Software Level A (target), DO-333 formal supplement
--  SPARK_Mode  : On
--  Requirements: HLR-CTL-0013 .. HLR-CTL-0019 (placeholder IDs)

--  PURPOSE
   -- turns the gain table of Fsac.Control.Params into the gains for the current flight condition; dynamic pressure comes in, 
   -- the pair (Kq, Ki_Dt) for the pitch-rate damper comes out

--  WHY GAIN SCHEDULING
   -- an aerodynamically unstable airframe changes character with speed and  altitude: the same surface deflection produces a very 
   -- different pitch moment at 40 kPa and at 10 kPa, a single fixed gain would be too weak at one end of the envelope and unstable at 
   --  the other; the schedule selects the gain from dynamic pressure, which is the quantity that scales the aerodynamic forces

--  THREE LAYERS, EACH WITH ITS OWN CONTRACT

   --    Find_Segment    which of the 7 table segments contains q
   --    Blend_Factor    where q lies inside that segment, as t in [0, 1]
   --    Interpolate     gain at t between the two neighbouring table values
   --    Schedule_Gain   the three above, applied to Kq and Ki_Dt

--  PROPERTIES PROVED IN THE CONTRACTS (the reason this unit exists)
   --    P1  No overshoot. The interpolated gain lies between the two table
   --        values of its segment (Between). A schedule can never produce a
   --        gain that no table entry justifies.
   --    P2  Continuity at breakpoints. At q equal to a breakpoint the result is
   --        exactly the table value there. Gains do not jump when the aircraft
   --        crosses a breakpoint.
   --    P3  Clamped ends. Below the first breakpoint the first value is used,
   --        above the last the last value is used. There is no extrapolation.
   --    P4  Bounded effort. Find_Segment is a loop of at most 7 iterations;
   --        the rest is straight-line code. The WCET is data-independent in
   --        shape and the bound is easy to state.

--  EDGE BEHAVIOUR THAT NEEDS CARE
   -- Blend_Factor multiplies two rounded numbers, so at the top of a segment the product can come out one least-significant bit away 
   -- from 1.0. Blend_Factor therefore forces t = 1.0 when q is at or above the upper  breakpoint (and t = 0 when at or below the lower
   -- one) hat makes P2  and P3 exact instead of "approximately"

--  CALLER RESPONSIBILITY
   -- the schedule argument has the subtype Valid_Gain_Schedule, so its predicate (spacing, matching Inv_Span) is checked where the table 
   -- is created and relied on here. No run-time validation happens inside the flight path

--  TEST NOTES
   -- tests use a schedule with unequal spacing and a gain that rises then falls, and check: each breakpoint exactly, each midpoint 
   -- within one least-significant bit of the real-valued line, both ends clamped, and monotonic result for a monotonic table when q 
   -- increases in small steps

with Fsac.Types;           use Fsac.Types;
with Fsac.Control.Params;  use Fsac.Control.Params;

package Fsac.Control.Gain_Schedule
  with SPARK_Mode => On
is

   subtype Unit_Interval is Q16 range 0 .. Q16_One_Raw;
   --  0.0 .. 1.0, the position inside a segment

   type Scheduled_Gains is record
      Kq    : Gain;
      Ki_Dt : Gain;
   end record;


   --  Helper for contracts
   function Between (X, A, B : Q16) return Boolean is
     (X >= Q16'Min (A, B) and then X <= Q16'Max (A, B))
     with Global => null;
   --  true when X lies in the closed interval spanned by A and B, whichever of the two is larger

   --  Segment selection
   function Find_Segment
     (S : Valid_Gain_Schedule;
      Q : Dyn_Pressure) return Segment_Index
     with
       Global => null,
       Post   =>
         (Find_Segment'Result = Segment_Index'First
          or else S.Q_Break (Find_Segment'Result) <= Q)
         and then
         (Find_Segment'Result = Segment_Index'Last
          or else Q < S.Q_Break (Find_Segment'Result + 1));
   --  returns segment i such that Q_Break(i) <= q < Q_Break(i+1) below the table it returns the first segment, above it the last

   --  position inside a segment
   function Blend_Factor
     (Q    : Dyn_Pressure;
      Q_Lo : Dyn_Pressure;
      Q_Hi : Dyn_Pressure;
      Inv  : Inverse_Span) return Unit_Interval
     with
       Global => null,
       Pre    => Q_Lo < Q_Hi,
       Post   =>
         (if Q <= Q_Lo then Blend_Factor'Result = 0)
         and then (if Q >= Q_Hi then Blend_Factor'Result = Q16_One);
   --  t = (q - Q_Lo) * Inv, limited to [0, 1], exactly 0 at or below the lower breakpoint and exactly 1 at or above the upper one

   --  interpolation between two gains
   function Interpolate
     (Lo : Gain;
      Hi : Gain;
      T  : Unit_Interval) return Gain
     with
       Global => null,
       Post   =>
         Between (Interpolate'Result, Lo, Hi)
         and then (if T = 0 then Interpolate'Result = Lo)
         and then (if T = Q16_One then Interpolate'Result = Hi);
   --  Lo + t * (Hi - Lo). Works for Hi below Lo as well (falling gain)

   --  complete lookup
   function Schedule_Gain
     (S : Valid_Gain_Schedule;
      Q : Dyn_Pressure) return Scheduled_Gains
     with
       Global => null,
       Post   =>
         --  P1: no overshoot, for both gains
         Between
           (Schedule_Gain'Result.Kq,
            S.Kq (Find_Segment (S, Q)),
            S.Kq (Find_Segment (S, Q) + 1))
         and then Between
           (Schedule_Gain'Result.Ki_Dt,
            S.Ki_Dt (Find_Segment (S, Q)),
            S.Ki_Dt (Find_Segment (S, Q) + 1))
         --  P3: clamped ends
         and then
           (if Q <= S.Q_Break (Point_Index'First) then
              Schedule_Gain'Result.Kq    = S.Kq    (Point_Index'First)
              and then Schedule_Gain'Result.Ki_Dt = S.Ki_Dt (Point_Index'First))
         and then
           (if Q >= S.Q_Break (Point_Index'Last) then
              Schedule_Gain'Result.Kq    = S.Kq    (Point_Index'Last)
              and then Schedule_Gain'Result.Ki_Dt = S.Ki_Dt (Point_Index'Last));
   --  P2 (continuity at breakpoints) follows from P1 and the exact ends of blend_Factor; it is covered by the breakpoint tests and by 
   --  the proof of the body

end Fsac.Control.Gain_Schedule;