{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}
module Fregot.PrettyPrint
    ( module Fregot.PrettyPrint.Internal
    , module Fregot.PrettyPrint.Sem

    , pretty'
    , array
    , set
    , object
    ) where

import           Data.Foldable               (toList)
import           Fregot.PrettyPrint.Internal
import           Fregot.PrettyPrint.Sem

pretty' :: Pretty Sem a => a -> SemDoc
pretty' = pretty

array :: (Foldable f, Pretty Sem a) => f a -> SemDoc
array = parensSepVert
    (punctuation "[") (punctuation "]") (punctuation ",") .
    map pretty . toList

set :: Pretty Sem a => [a] -> SemDoc
set a = parensSepVert
    (punctuation "{") (punctuation "}") (punctuation ",")
    (map pretty a)

object :: (Pretty Sem k, Pretty Sem v) => [(k, v)] -> SemDoc
object o = parensSepVert
    (punctuation "{") (punctuation "}") (punctuation ",")
    [ pretty k <> punctuation ":" <+> pretty t
    | (k, t) <- o
    ]
