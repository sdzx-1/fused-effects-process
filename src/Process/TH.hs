{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE DataKinds #-}
module Process.TH
    ( mkSigAndClass
    , mkMetric
    ) where

import           Data.Maybe
import           Language.Haskell.TH

mkSigAndClass :: String -> [Name] -> Q [Dec]
mkSigAndClass sname gs = do
    sig <- mkSig sname gs
    cls <- mkClass sname gs
    ins <- mkTypeIns sname gs
    pure $ sig ++ cls ++ ins

mkSig :: String -> [Name] -> Q [Dec]
mkSig sname gs = do
    let t1  = mkName sname
        dec = DataD
            []
            t1
            [PlainTV (mkName "a") ()]
            Nothing
            [ GadtC
                  [mkName (sname ++ show idx)]
                  [(Bang NoSourceUnpackedness NoSourceStrictness, ConT g1)]
                  (AppT (ConT t1) (ConT g1))
            | (idx, g1) <- zip [1 ..] gs
            ]
            []
    pure [dec]

mkClass :: String -> [Name] -> Q [Dec]
mkClass sname gs = do
    tosig  <- fromMaybe (error "not find ToSig") <$> lookupTypeName "ToSig"
    method <- fromMaybe (error "not find toSig") <$> lookupValueName "toSig"
    let
        decs =
            [ InstanceD
                  Nothing
                  []
                  (AppT (AppT (ConT tosig) (ConT g1)) (ConT (mkName sname)))
                  [ FunD
                        method
                        [ Clause
                              [VarP $ mkName "ms"]
                              (NormalB
                                  (AppE (ConE (mkName (sname ++ show idx)))
                                        (VarE (mkName "ms"))
                                  )
                              )
                              []
                        ]
                  ]
            | (idx, g1) <- zip [1 ..] gs
            ]
    pure decs

mkTypeIns :: String -> [Name] -> Q [Dec]
mkTypeIns sname gs = do
    toListT <- fromMaybe (error "not find ToList") <$> lookupTypeName "ToList"
    let ds  = [ AppT PromotedConsT (ConT g1) | g1 <- gs ]
        dec = TySynInstD
            (TySynEqn Nothing
                      (AppT (ConT toListT) (ConT (mkName sname)))
                      (foldr AppT PromotedNilT ds)
            )
    pure [dec]

mkMetric :: String -> [String] -> Q [Dec]
mkMetric bn ls = do
    classTypeDef <- fromMaybe (error "you need impore Data.Default.Class ")
        <$> lookupTypeName "Default"
    classTypeLen <- fromJust <$> lookupTypeName "Vlength"

    let contTypeV = mkName bn
    methodDef <- fromMaybe (error "you need impore Data.Default.Class ")
        <$> lookupValueName "def"
    methodVlen <- fromJust <$> lookupValueName "vlength"

    let vVal = mkName bn
    kVal <- fromJust <$> lookupValueName "K"
    let aal = foldl (\acc var -> AppE acc (ConE var))
                    (ConE vVal)
                    (replicate (Prelude.length ls) kVal)
    let iDec = InstanceD Nothing
                         []
                         (AppT (ConT classTypeDef) (ConT contTypeV))
                         [mDec]
        mDec  = ValD (VarP methodDef) (NormalB aal) []

        iDec1 = InstanceD Nothing
                          []
                          (AppT (ConT classTypeLen) (ConT contTypeV))
                          [iFun]
        iFun = FunD
            methodVlen
            [ Clause [WildP]
                     (NormalB (LitE (IntegerL $ fromIntegral $ length ls)))
                     []
            ]

    kType <- fromJust <$> lookupTypeName "K"
    let ddd  = DataD [] (mkName bn) [] Nothing [cons] []
        cons = RecC
            (mkName bn)
            [ ( mkName b
              , Bang NoSourceUnpackedness NoSourceStrictness
              , AppT (ConT kType) (LitT (StrTyLit (show a)))
              )
            | (a, b) <- zip [0, 1 ..] ls
            ]
    pure [ddd, iDec, iDec1]
