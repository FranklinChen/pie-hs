{-# OPTIONS_GHC -fwarn-incomplete-patterns #-}
-- | Checking expressions for alpha-equivalence.
module Pie.AlphaEquiv (alphaEquiv) where

import Pie.Types

-- | Check two core expressions for alpha-equivalence.
--
-- If they are alpha-equivalent, return @Right ()@. If they are not,
-- return @Left@ wrapped around a pair of subexpressions that differ.
alphaEquiv :: Core -> Core -> Either (Core, Core) ()
alphaEquiv e1 e2 = runAlpha (equiv e1 e2) [] [] 0

newtype Alpha a =
  Alpha { runAlpha ::
            [(Symbol, Integer)] -> [(Symbol, Integer)] ->
            Integer ->
            Either (Core, Core) a
        }

instance Functor Alpha where
  fmap f (Alpha act) = Alpha (\ l r i -> fmap f (act l r i))

instance Applicative Alpha where
  pure x = Alpha (\ _ _ _ -> Right x)
  Alpha fun <*> Alpha arg =
    Alpha (\ l r i -> fun l r i <*> arg l r i)



withEquiv :: Symbol -> Symbol -> Alpha a -> Alpha a
withEquiv x y (Alpha act) =
  Alpha (\ l r i -> act ((x, i) : l) ((y, i) : r) (i + 1))

notEquiv :: Core -> Core -> Alpha a
notEquiv e1 e2 = Alpha (\ l r i -> Left (e1, e2))

equivVars :: Symbol -> Symbol -> Alpha ()
equivVars x y =
  Alpha (\l r _ ->
           case (lookup x l, lookup y r) of
             (Nothing, Nothing)
               | x == y    -> pure ()
               | otherwise -> Left (CVar x, CVar y)
             (Just i, Just j)
               | i == j    -> pure ()
               | otherwise -> Left (CVar x, CVar y)
             _ -> Left (CVar x, CVar y))

equiv :: Core -> Core -> Alpha ()
equiv e1 e2 =
  case (e1, e2) of
    (CTick x, CTick y) ->
      require (x == y)
    (CAtom, CAtom) ->
      yes
    (CZero, CZero) ->
      yes
    (CAdd1 j, CAdd1 k) ->
      equiv j k
    (CWhichNat tgt1 bt1 base1 step1, CWhichNat tgt2 bt2 base2 step2) ->
      equiv tgt1 tgt2 *> equiv bt1 bt2 *> equiv base1 base2 *> equiv step1 step2
    (CIterNat tgt1 bt1 base1 step1, CIterNat tgt2 bt2 base2 step2) ->
      equiv tgt1 tgt2 *> equiv bt1 bt2 *> equiv base1 base2 *> equiv step1 step2
    (CRecNat tgt1 bt1 base1 step1, CRecNat tgt2 bt2 base2 step2) ->
      equiv tgt1 tgt2 *> equiv bt1 bt2 *> equiv base1 base2 *> equiv step1 step2
    (CIndNat tgt1 mot1 base1 step1, CIndNat tgt2 mot2 base2 step2) ->
      equiv tgt1 tgt2 *>
      equiv mot1 mot2 *>
      equiv base1 base2 *>
      equiv step1 step2
    (CNat, CNat) ->
      yes
    (CVar x, CVar y) ->
      equivVars x y
    (CPi x dom1 ran1, CPi y dom2 ran2) ->
      equiv dom1 dom2 *>
      withEquiv x y (equiv ran1 ran2)
    (CLambda x body1, CLambda y body2) ->
      withEquiv x y (equiv body1 body2)
    (CApp rator1 rand1, CApp rator2 rand2) ->
      equiv rator1 rator2 *>
      equiv rand1 rand2
    (CSigma x a1 d1, CSigma y a2 d2) ->
      equiv a1 a2 *>
      withEquiv x y (equiv d1 d2)
    (CCons a1 d1, CCons a2 d2) ->
      equiv a1 a2 *> equiv d1 d2
    (CCar p1, CCar p2) -> equiv p1 p2
    (CCdr p1, CCdr p2) -> equiv p1 p2
    (CTrivial, CTrivial) -> yes
    (CSole, CSole) -> yes
    (CEq a f1 t1, CEq b f2 t2) ->
      equiv a b *> equiv f1 f2 *> equiv t1 t2
    (CSame e1, CSame e2) ->
      equiv e1 e2
    (CReplace tgt1 mot1 base1, CReplace tgt2 mot2 base2) ->
      equiv tgt1 tgt2 *> equiv mot1 mot2 *> equiv base1 base2
    (CTrans a1 b1, CTrans a2 b2) ->
      equiv a1 a2 *> equiv b1 b2
    (CCong a1 b1 c1, CCong a2 b2 c2) ->
      equiv a1 a2 *> equiv b1 b2 *> equiv c1 c2
    (CSymm p1, CSymm p2) ->
      equiv p1 p2
    (CIndEq tgt1 mot1 base1, CIndEq tgt2 mot2 base2) ->
      equiv tgt1 tgt2 *> equiv mot1 mot2 *> equiv base1 base2
    (CList e1, CList e2) -> equiv e1 e2
    (CListNil, CListNil) -> yes
    (CListCons e1 es1, CListCons e2 es2) -> equiv e1 e2 *> equiv es1 es2
    (CRecList tgt1 bt1 base1 step1, CRecList tgt2 bt2 base2 step2) ->
      equiv tgt1 tgt2 *> equiv bt1 bt2 *> equiv base1 base2 *> equiv step1 step2
    (CIndList tgt1 mot1 base1 step1, CIndList tgt2 mot2 base2 step2) ->
      equiv tgt1 tgt2 *> equiv mot1 mot2 *> equiv base1 base2 *> equiv step1 step2
    (CVec e1 len1, CVec e2 len2) -> equiv e1 e2 *> equiv len1 len2
    (CVecNil, CVecNil) -> yes
    (CVecCons e1 es1, CVecCons e2 es2) ->
      equiv e1 e2 *> equiv es1 es2
    (CVecHead es1, CVecHead es2) -> equiv es1 es2
    (CVecTail es1, CVecTail es2) -> equiv es1 es2
    (CIndVec len1 es1 mot1 base1 step1, CIndVec len2 es2 mot2 base2 step2) ->
      equiv len1 len2 *>
      equiv es1 es2 *>
      equiv mot1 mot2 *>
      equiv base1 base2 *>
      equiv step1 step2
    (CEither l1 r1, CEither l2 r2) ->
      equiv l1 l2 *> equiv r1 r2
    (CLeft l1, CLeft l2) -> equiv l1 l2
    (CRight r1, CRight r2) -> equiv r1 r2
    (CIndEither tgt1 mot1 left1 right1, CIndEither tgt2 mot2 left2 right2) ->
      equiv tgt1 tgt2 *>
      equiv mot1 mot2 *>
      equiv left1 left2 *>
      equiv right1 right2
    (CAbsurd, CAbsurd) -> yes
    (CIndAbsurd tgt1 mot1, CIndAbsurd tgt2 mot2) ->
      equiv tgt1 tgt2 *> equiv mot1 mot2
    -- Part of AbsSame-η from p. 388. See readBack for the other part.
    (CThe CAbsurd _, CThe CAbsurd _) -> yes
    (CThe t1 e1, CThe t2 e2) ->
      equiv t1 t2 *> equiv e1 e2
    (CU, CU) ->
      yes
    (CTODO loc1 _, CTODO loc2 _) ->
      require (loc1 == loc2)
    _ ->
      no

  where
    yes = pure ()
    no = notEquiv e1 e2
    require b = if b then yes else no
