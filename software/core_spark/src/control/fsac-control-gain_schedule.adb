--  ===========================================================================
--  FSAC - Flight Stability Augmentation Computer
--  ===========================================================================
--  File        : software/core_spark/src/control/fsac-control-gain_schedule.adb
--  Package     : Fsac.Control.Gain_Schedule  (body)
--  Language    : Ada 2012 / SPARK 2014
--  Assurance   : DO-178C Software Level A (target), DO-333 formal supplement
--  SPARK_Mode  : On
--  Requirements: HLR-CTL-0013 .. HLR-CTL-0019 (placeholder IDs)

--  PURPOSE
   -- implements the contracts of fsac-control-gain_schedule.ads; this is the
   -- first unit in the project with a loop, so it is also the first where the
   -- prover needs written guidance (a loop invariant) and where the guidance
   -- has to be reviewed like code

--  WHAT GNATPROVE MUST SHOW HERE
   --    Unit           Check                               Expected result
   --    -------------  ---------------------------------  --------------------
   --    Find_Segment   index check on Q_Break (I + 1)     proved, I <= 7
   --    Find_Segment   Post (both halves)                 proved with the loop
   --                                                      invariant below
   --    Blend_Factor   Pre of Clamp (0 <= 1.0)            proved, constants
   --    Blend_Factor   Post (exact 0 and exact 1)         proved, early returns
   --    Interpolate    Pre of Clamp (Min <= Max)          proved
   --    Interpolate    Post (Between, exact ends)         proved, see note 2
   --    Schedule_Gain  Pre of Blend_Factor (Lo < Hi)      needs the ordering
   --                                                      facts, see note 1
   --    Schedule_Gain  Post (P1 and P3)                   follows from the
   --                                                      contracts of callees
   --                                                      plus ordering

--  NOTE 1: ORDERING FACTS FOR THE PROVER
   -- the table predicate (Well_Formed) says that every segment is at least
   -- 1 kPa wide, as a quantified statement; solvers do not always instantiate
   -- a quantifier on their own; the seven assertions at the top of
   -- Schedule_Gain write the seven instances out, one per segment; each one
   -- is proved from the predicate, together they give the full chain
   -- Q_Break(1) < ... < Q_Break(8), which the edge properties (P3) need

--  NOTE 2: WHY INTERPOLATE ENDS WITH A CLAMP
   -- mathematically Lo + t * (Hi - Lo) already lies between Lo and Hi, and
   -- truncation toward zero cannot move it outside, proving that from the
   -- product needs non-linear reasoning, which is the hard kind; the final
   -- Clamp to [Min (Lo, Hi), Max (Lo, Hi)] makes the property true by
   -- construction and provable by simple comparison; it costs two comparisons
   -- and removes a proof that depends on the solver's mood, this trade
   -- (a few instructions for a robust proof) is deliberate

--  NOTE 3: LOOP INVARIANT PLACEMENT
   -- the invariant is the last statement of the loop body. For a for-loop the
   -- prover then knows the invariant for the final value of I when the loop
   -- ends without having returned; that is exactly the fact the last return
   -- statement needs (q is at or above Q_Break(7) and Q_Break(8)).

--  TIMING SHAPE
   -- Find_Segment: at most 7 iterations, each one comparison; everything else:
   -- straight-line code, three calls into Fixed_Math; no data-dependent
   -- recursion, no allocation

with Fsac.Fixed_Math; use Fsac.Fixed_Math;

package body Fsac.Control.Gain_Schedule
  with SPARK_Mode => On
is

   pragma Compile_Time_Error
     (Num_Points /= 8,
      "Update the ordering assertions in Schedule_Gain for the new size");

   --  Find_Segment
   function Find_Segment
     (S : Valid_Gain_Schedule;
      Q : Dyn_Pressure) return Segment_Index
   is
   begin
      for I in Segment_Index loop
         if Q < S.Q_Break (I + 1) then
            return I;
         end if;

         pragma Loop_Invariant
           (for all K in Segment_Index'First .. I =>
              Q >= S.Q_Break (K + 1));
      end loop;

      --  here q is at or above the upper breakpoint of every segment, so it
      --  belongs to the last one (clamped, no extrapolation)
      return Segment_Index'Last;
   end Find_Segment;

   --  Blend_Factor
   function Blend_Factor
     (Q    : Dyn_Pressure;
      Q_Lo : Dyn_Pressure;
      Q_Hi : Dyn_Pressure;
      Inv  : Inverse_Span) return Unit_Interval
   is
   begin
      if Q <= Q_Lo then
         return 0;
      elsif Q >= Q_Hi then
         return Q16_One;
      else
         declare
            Offset : constant Q16 := Sub_Sat (Q, Q_Lo);
            T_Raw  : constant Q16 := Mul_Q (Offset, Inv);
         begin
            return Clamp (T_Raw, 0, Q16_One);
         end;
      end if;
   end Blend_Factor;

   --  interpolate
   function Interpolate
     (Lo : Gain;
      Hi : Gain;
      T  : Unit_Interval) return Gain
   is
   begin
      if T = 0 then
         return Lo;
      elsif T = Q16_One then
         return Hi;
      else
         declare
            Delta_G    : constant Q16 := Sub_Sat (Hi, Lo);
            Step       : constant Q16 := Mul_Q (Delta_G, T);
            Raw        : constant Q16 := Add_Sat (Lo, Step);
            Low_Bound  : constant Q16 := Q16'Min (Lo, Hi);
            High_Bound : constant Q16 := Q16'Max (Lo, Hi);
         begin
            --  see note 2 in the file header
            return Clamp (Raw, Low_Bound, High_Bound);
         end;
      end if;
   end Interpolate;

   --  Schedule_Gain
   function Schedule_Gain
     (S : Valid_Gain_Schedule;
      Q : Dyn_Pressure) return Scheduled_Gains
   is
   begin
      --  ordering facts, one per segment (see note 1 in the file header)
      pragma Assert (S.Q_Break (1) < S.Q_Break (2));
      pragma Assert (S.Q_Break (2) < S.Q_Break (3));
      pragma Assert (S.Q_Break (3) < S.Q_Break (4));
      pragma Assert (S.Q_Break (4) < S.Q_Break (5));
      pragma Assert (S.Q_Break (5) < S.Q_Break (6));
      pragma Assert (S.Q_Break (6) < S.Q_Break (7));
      pragma Assert (S.Q_Break (7) < S.Q_Break (8));

      declare
         I : constant Segment_Index := Find_Segment (S, Q);
      begin
         --  the same fact for the segment actually selected; this is the Pre
         --  of Blend_Factor (Q_Lo < Q_Hi), stated where the prover needs it
         --  instead of leaving it to a case split over I
         pragma Assert (Span (S, I) >= Wide (Min_Span_Raw));

         declare
            T : constant Unit_Interval :=
              Blend_Factor
                (Q    => Q,
                 Q_Lo => S.Q_Break (I),
                 Q_Hi => S.Q_Break (I + 1),
                 Inv  => S.Inv_Span (I));
         begin
            return
              (Kq    => Interpolate (S.Kq    (I), S.Kq    (I + 1), T),
               Ki_Dt => Interpolate (S.Ki_Dt (I), S.Ki_Dt (I + 1), T));
         end;
      end;
   end Schedule_Gain;

end Fsac.Control.Gain_Schedule;