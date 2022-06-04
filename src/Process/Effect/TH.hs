{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LinearTypes #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies #-}

module Process.Effect.TH (mkSigAndClass) where

import Data.Maybe (fromMaybe)
import Language.Haskell.TH
  ( Bang (..),
    Body (..),
    Con (GadtC),
    Dec (..),
    Exp (..),
    Inline (..),
    Name,
    Pat (..),
    Phases (..),
    Pragma (..),
    Q,
    RuleMatch (..),
    SourceStrictness (..),
    SourceUnpackedness (..),
    TySynEqn (..),
    TyVarBndr (..),
    Type (..),
    lookupTypeName,
    lookupValueName,
    mkName,
  )

mkSigAndClass :: String -> [Name] -> Q [Dec]
mkSigAndClass sname gs = do
  sig <- mkSig sname gs
  cls <- mkClass sname gs
  ins <- mkTypeIns sname gs
  pure $ sig ++ cls ++ ins

mkSig :: String -> [Name] -> Q [Dec]
mkSig sname gs = do
  let sig = mkName sname
      n1 = mkName "n"
      s1 = mkName "s"
      dec =
        DataD
          []
          sig
          [ PlainTV n1 (),
            PlainTV s1 ()
          ]
          Nothing
          [ GadtC
              [mkName (sname ++ show idx)]
              [ ( Bang NoSourceUnpackedness NoSourceStrictness,
                  AppT (ConT g1) (VarT n1)
                )
              ]
              ( AppT
                  (AppT (ConT sig) (VarT n1))
                  (AppT (ConT g1) (VarT n1))
              )
            | (idx, g1) <- zip [1 ..] gs
          ]
          []
  pure [dec]

mkClass :: String -> [Name] -> Q [Dec]
mkClass sname gs = do
  tosig <- fromMaybe (error "not find ToSig") <$> lookupTypeName "ToSig"
  method <- fromMaybe (error "not find toSig") <$> lookupValueName "toSig"
  let decs =
        [ InstanceD
            Nothing
            []
            ( AppT
                ( AppT
                    ( AppT
                        (ConT tosig)
                        (ConT g1)
                    )
                    (ConT (mkName sname))
                )
                (VarT (mkName "n"))
            )
            [ ValD
                (VarP method)
                (NormalB (ConE (mkName (sname ++ show idx))))
                [],
              PragmaD (InlineP method Inline FunLike AllPhases)
            ]
          | (idx, g1) <- zip [1 ..] gs
        ]
  pure decs

mkTypeIns :: String -> [Name] -> Q [Dec]
mkTypeIns sname gs = do
  toListT <- fromMaybe (error "not find ToList") <$> lookupTypeName "ToList"
  let ds =
        [ AppT
            PromotedConsT
            ( AppT
                (ConT g1)
                (VarT (mkName "n"))
            )
          | g1 <- gs
        ]
      dec =
        TySynInstD
          ( TySynEqn
              Nothing
              ( AppT
                  (ConT toListT)
                  ( AppT
                      (ConT (mkName sname))
                      (VarT (mkName "n"))
                  )
              )
              (foldr AppT PromotedNilT ds)
          )
  pure [dec]
