--  ===========================================================================
--  FSAC - Flight Stability Augmentation Computer
--  ===========================================================================
--  File        : software/core_spark/src/math/fsac-fixed_math.adb
--  Package     : Fsac.Fixed_Math  (body)
--  Language    : Ada 2012 / SPARK 2014
--  Assurance   : DO-178C Software Level A (target), DO-333 formal supplement
--  SPARK_Mode  : On
--  Requirements: HLR-NUM-0010 .. HLR-NUM-0018 (placeholder IDs)

-- PURPOSE
   -- implements the contracts declared in fsac-fixed_math.ads, each body is
   -- deliberately tiny: straight-line code or a single if/elsif chain, no
   -- loops, no recursion, no allocation, no exceptions; that keeps the
   -- structural-coverage argument simple (every branch is reached by the
   -- corner-value tests) and the proof obligations small

-- WHAT GNATPROVE MUST SHOW HERE (and how each item is expected to prove)
   --    Function    Check                                   Expected result
   --    ----------  --------------------------------------  -------------------
   --    Saturate    range check on Q16 (X) conversion       proved from the
   --                                                        branch conditions
   --    Clamp       Post (four implications)                proved, case split
   --    Add_Sat     overflow of Wide (A) + Wide (B)         proved: |sum| <= 2**32
   --    Sub_Sat     overflow of Wide (A) - Wide (B)         proved: |diff| <= 2**32
   --    Mul_Q       overflow of Wide (A) * Wide (B)         NONLINEAR, may need
   --                                                        the guiding asserts
   --    Mul_Q       division check (divisor is a constant)  proved, constant /= 0
   --    Neg         overflow of unary minus                 proved: the range is
   --                                                        symmetric (Fsac.Types)
   --    Abs_Q       overflow of "abs"                       proved, same reason
   --    To_*        range check on the returned value       proved from branches

-- IF Mul_Q DOES NOT PROVE AT THE FIRST RUN
   -- the product of two 31-bit values is a non-linear fact, and SMT solvers
   -- sometimes need a hint; in order:
      -- 1. run with --level=3 or --level=4 (more provers, longer timeout)
      -- 2. keep the two pragma Assert statements below; if one of them is
      --    reported as unproved, that line shows exactly which bound the
      --    solver cannot see
      -- 3. last resort: replace the product by a loop-free split into 16-bit
      --    halves (high and low) and prove each partial product linearly;
      --    document the change in ADR-005 and re-review the unit

-- CODING RULES APPLIED
   -- * No raw "+", "-", "*" on Q16 outside this package
   -- * intermediate values live in Wide and are narrowed only through Saturate
   -- * every function has Global => null (no hidden state)

package body Fsac.Fixed_Math
   with SPARK_Mode => On
is

   -- saturate
   function Saturate (X : Wide) return Q16 is
   begin
      if X > Wide (Q16'Last) then
         return Q16'Last;
      elsif X < Wide (Q16'First) then
         return Q16'First;
      else
         return Q16 (X);
      end if;
   end Saturate;

   -- clamp
   function Clamp (X, Lo, Hi : Q16) return Q16 is
   begin
      if X < Lo then
         return Lo;
      elsif X > Hi then
         return Hi;
      else
         return X;
      end if;
   end Clamp;

   -- Add_Sat, Sub_Sat
   function Add_Sat (A, B : Q16) return Q16 is
   begin
      return Saturate (Wide (A) + Wide (B));
   end Add_Sat;

   function Sub_Sat (A, B : Q16) return Q16 is
   begin
      return Saturate (Wide (A) - Wide (B));
   end Sub_Sat;

   --  Mul_Q
   function Mul_Q (A, B : Q16) return Q16 is
      Product : constant Wide := Wide (A) * Wide (B);
   begin
      --  guiding assertions for the prover; they restate what Fsac.Types
      --  already guarantees (both factors are below 2**31 in magnitude,
      --  so the product is below 2**62) in the form that the overflow
      --  check on the line above needs
      pragma Assert (Product >= -(2**62));
      pragma Assert (Product <= 2**62);

      return Saturate (Product / Wide (Q16_One_Raw));
   end Mul_Q;

   --  Neg, Abs_Q
   function Neg (X : Q16) return Q16 is
   begin
      return -X;
   end Neg;

   function Abs_Q (X : Q16) return Q16 is
   begin
      return abs X;
   end Abs_Q;

   --  conversions into physical subtypes
   function To_Body_Rate (X : Q16) return Body_Rate is
   begin
      if X < Body_Rate'First then
         return Body_Rate'First;
      elsif X > Body_Rate'Last then
         return Body_Rate'Last;
      else
         return X;
      end if;
   end To_Body_Rate;

   function To_Rate_Error (X : Q16) return Rate_Error is
   begin
      if X < Rate_Error'First then
         return Rate_Error'First;
      elsif X > Rate_Error'Last then
         return Rate_Error'Last;
      else
         return X;
      end if;
   end To_Rate_Error;

   function To_Surface_Cmd (X : Q16) return Surface_Cmd is
   begin
      if X < Surface_Cmd'First then
         return Surface_Cmd'First;
      elsif X > Surface_Cmd'Last then
         return Surface_Cmd'Last;
      else
         return X;
      end if;
   end To_Surface_Cmd;

end Fsac.Fixed_Math;