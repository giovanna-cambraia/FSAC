--  ===========================================================================
--  FSAC - Flight Stability Augmentation Computer
--  ===========================================================================
--  File        : software/core_spark/src/math/fsac-fixed_math.ads
--  Package     : Fsac.Fixed_Math  (specification; body in fsac-fixed_math.adb)
--  Language    : Ada 2012 / SPARK 2014
--  Assurance   : DO-178C Software Level A (target), DO-333 formal supplement
--  SPARK_Mode  : On
--  Requirements: HLR-NUM-0010 .. HLR-NUM-0018 (placeholder IDs)
--  Decision    : ADR-005

-- PURPOSE
   -- the only place where Q16 arithmetic is performed; control laws, signal management and allocation call these functions and never
   -- use the raw "+", "-", "*" operators on Q16 values, that rule is what makes the absence of runtime errors proof of the whole core
   -- traceable: overflow is proved impossible once, and every caller inherits the result 

-- SATURATION POLICY
   -- every operation returns the mathematically exacy result when it is representable and the nearest representable value (Q16'First
   -- or Q16'LAST) otherwise; saturation never raises an exception and takes a fixed number of instructions, so the WCET does not 
   -- depend on the data, a saturated value is a legitimate flight outcome (large error, strong gust); callers that need to know it
   -- occurred compare against the limits, they do not rely on an exception 

-- ROUNDING POLICY
   -- multiplication discards 16 fractional bits of the extra precision by truncation toward zero (Ada "/" on integers); truncation
   -- toward zero is symmetric around 0, so positive and negative signals are treated identically and no sign-dependent bias is
   -- introduced; the maximum errror per product is one least-significant bit (2**-16); the effect on loop behavior is analysed in
   -- MIL (limit cycles near zero error)

-- CONTRACT SUMMARY 
   --    Function     Guarantee (Post)
   --    -----------  -------------------------------------------------------
   --    Saturate     exact value if representable, else nearest bound
   --    Clamp        result lies in [Lo, Hi]; X unchanged when already inside
   --    Add_Sat      Saturate (A + B) computed in Wide
   --    Sub_Sat      Saturate (A - B) computed in Wide
   --    Mul_Q        Saturate ((A * B) / 2**16) computed in Wide, truncating
   --    Neg          exactly -X (cannot overflow, range is symmetric)
   --    Abs_Q        exactly abs X (cannot overflow, range is symmetric)
   --    To_*         clamp into the named physical subtype

-- PROOF EXPECTATIONS (GNATprove, level 2 or higher)
   -- * no overflow, range or division check can fail in any body
   -- * every post is discharged by the body
   -- * callers only need to establish the Pre of Clamp (Lo <= Hi)
   -- all items are expected to prove automatically with the default provers; if Mul_Q needs help, the body contains the intermediate
   -- assertions that guide the solver

-- TEST NOTES
   -- verification/requirements_tests/ checks each function at the corner values: Q16'First, Q16'Last, 0, +-1, +-One, and the two 
   -- values next to each limit; the expected values come from an independent Python reference model, not from this code

with Fsac.Types; use Fsac.Types;

package Fsac.Fixed_Math 
   with SPARK_Mode => On 
is 

   -- narrowing from the wide type
   function Saturate (X : Wide) return Q16
      with 
         Global => null,
         Post =>
            (if X > Wide (Q16'Last) then Saturate'Result = Q16'Last elsif X < Wide (Q16'First) then Saturate'Result = Q16'First else Wide (Saturate'Result) = X);
            -- converts a wide value Q16 with saturation

   -- limiting 
   function Clamp (X, Lo, Hi : Q16) return Q16
      with
         Global   => null,
         Pre      => Lo <= Hi,
         Post     => 
            Clamp'Result in Lo .. Hi 
            and then (if X in Lo .. Hi then Clamp'Result = X)
            and then (if X < Lo then Clamp'Result = Lo)
            and then (if X > Hi then Clamp'Result = Hi);
            -- limit X to the closed interval [Lo, Hi]

   -- arithmetic 
   function Add_Sat (A, B : Q16) return Q16
      with
         Global   => null,
         Post     => Add_Sat'Result = Saturate (Wide (A) + Wide (B));

   function Sub_Sat (A, B : Q16) return Q16
      with
         Global   => null,
         Post     => Sub_Sat'Result = Saturate (Wide (A) - Wide (B));
      
   function Mul_Q (A, B : Q16) return Q16
      with 
         Global   => null,
         Post     =>
            Mul_Q'Result =
               Saturate ((Wide (A) * Wide (B)) / Wide (Q16_One_Raw));
               -- Q16 x Q16 -> Q16, the product is formed in wide (no overflow is possible, see the compile-time check in Fsac.types), scaled back by 2**16 with truncation 
               -- toward zero, then saturated 

   function Neg (X : 16) return Q16
      with 
         Global   => null,
         Post     => Neg'Result = -X;

   function Abs_Q (X : Q16) return Q16
      with 
         Global   => null,
         Post     => 
            Abs_Q'Result >= 0
            and then (if X >= 0 then Abs_Q'Result = X else Abs_Q'Result = -X);

   -- conversion into physical subtypes (clamping)
   -- these are the sanctioned way to enter a physical subtype from a general Q16 value. because the result type carries the range, the prover knows the bound at every later 
   -- use without a separate check
   function To_Body_Rate (X : Q16) return Body_Rate
      with
         Global   => null,
         Post     =>
            (if X in Body_Rate then To_Body_Rate'Result = X
            elsif X < Body_Rate'First then To_Body_Rate'Result = Body_Rate'First
            else To_Body_Rate'Result = Body_Rate'Last);

   function To_Rate_Error (X : Q16) return Rate_Error
     with
       Global => null,
       Post   =>
         (if X in Rate_Error then To_Rate_Error'Result = X
          elsif X < Rate_Error'First then To_Rate_Error'Result = Rate_Error'First
          else To_Rate_Error'Result = Rate_Error'Last);

   function To_Surface_Cmd (X : Q16) return Surface_Cmd
     with
       Global => null,
       Post   =>
         (if X in Surface_Cmd then To_Surface_Cmd'Result = X
          elsif X < Surface_Cmd'First then To_Surface_Cmd'Result = Surface_Cmd'First
          else To_Surface_Cmd'Result = Surface_Cmd'Last);

end Fsac.Fixed_Math;

