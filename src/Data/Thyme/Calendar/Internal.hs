{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ViewPatterns #-}

-- #hide
module Data.Thyme.Calendar.Internal where

import Prelude
import Control.Applicative
import Control.DeepSeq
import Control.Lens
import Control.Monad
import Data.AffineSpace
import Data.Data
import Data.Int
import Data.Ix
import Data.Thyme.Format.Internal

-- | The Modified Julian Day is a standard count of days, with zero being
-- the day 1858-11-17.
newtype Day = ModifiedJulianDay
    { toModifiedJulianDay :: Int64
    } deriving (Eq, Ord, Enum, Ix, Bounded, NFData, Data, Typeable)

instance AffineSpace Day where
    type Diff Day = Int
    {-# INLINE (.-.) #-}
    ModifiedJulianDay a .-. ModifiedJulianDay b = fromIntegral (a - b)
    {-# INLINE (.+^) #-}
    ModifiedJulianDay a .+^ d = ModifiedJulianDay (a + fromIntegral d)

------------------------------------------------------------------------

type Year = Int
type Month = Int
type DayOfMonth = Int

data YearMonthDay = YearMonthDay
    { ymdYear :: {-# UNPACK #-}!Year
    , ymdMonth :: {-# UNPACK #-}!Month
    , ymdDay :: {-# UNPACK #-}!DayOfMonth
    } deriving (Eq, Ord, Data, Typeable, Show)

instance NFData YearMonthDay

------------------------------------------------------------------------

-- | Gregorian leap year?
{-# INLINE isLeapYear #-}
isLeapYear :: Year -> Bool
isLeapYear y = mod y 4 == 0 && (mod y 400 == 0 || mod y 100 /= 0)

type DayOfYear = Int
data OrdinalDate = OrdinalDate
    { odYear :: {-# UNPACK #-}!Year
    , odDay :: {-# UNPACK #-}!DayOfYear
    } deriving (Eq, Ord, Data, Typeable, Show)

instance NFData OrdinalDate

{-# INLINE ordinalDate #-}
ordinalDate :: Simple Iso Day OrdinalDate
ordinalDate = iso toOrd fromOrd where

    {-# INLINEABLE toOrd #-}
    toOrd :: Day -> OrdinalDate
    toOrd (ModifiedJulianDay mjd) = OrdinalDate
            (fromIntegral year) (fromIntegral yd) where
        -- pilfered
        a = mjd + 678575
        quadcent = div a 146097
        b = mod a 146097
        cent = min (div b 36524) 3
        c = b - cent * 36524
        quad = div c 1461
        d = mod c 1461
        y = min (div d 365) 3
        yd = d - y * 365 + 1
        year = quadcent * 400 + cent * 100 + quad * 4 + y + 1

    {-# INLINEABLE fromOrd #-}
    fromOrd :: OrdinalDate -> Day
    fromOrd (OrdinalDate year yd) = ModifiedJulianDay mjd where
        -- pilfered
        y = fromIntegral (year - 1)
        mjd = 365 * y + div y 4 - div y 100 + div y 400 - 678576
            + clip 1 (if isLeapYear year then 366 else 365) (fromIntegral yd)
        clip a b = max a . min b

------------------------------------------------------------------------

type WeekOfYear = Int
type DayOfWeek = Int

-- | Weeks numbered 01 to 53, where week 01 is the first week that has at
-- least 4 days in the new year. Days before week 01 are considered to
-- belong to the previous year.
data WeekDate = WeekDate
    { wdYear :: {-# UNPACK #-}!Year
    , wdWeek :: {-# UNPACK #-}!WeekOfYear
    , wdDay :: {-# UNPACK #-}!DayOfWeek
    } deriving (Eq, Ord, Data, Typeable, Show)

instance NFData WeekDate

{-# INLINE weekDate #-}
weekDate :: Simple Iso Day WeekDate
weekDate = iso toWeek fromWeek where

    {-# INLINEABLE toWeek #-}
    toWeek :: Day -> WeekDate
    toWeek = join (toWeekOrdinal . view ordinalDate)

    {-# INLINEABLE fromWeek #-}
    fromWeek :: WeekDate -> Day
    fromWeek wd@(WeekDate y _ _) = fromWeekLast (lastWeekOfYear y) wd

{-# INLINE toWeekOrdinal #-}
toWeekOrdinal :: OrdinalDate -> Day -> WeekDate
toWeekOrdinal (OrdinalDate y0 yd) (ModifiedJulianDay mjd) = WeekDate y1
        (fromIntegral $ w1 + 1) (fromIntegral $ d7mod + 1) where
    -- pilfered and refactored; no idea what foo and bar mean
    d = mjd + 2
    (d7div, d7mod) = divMod d 7
    foo :: Year -> {-WeekOfYear-1-}Int64
    foo y = bar $ review ordinalDate (OrdinalDate y 6)
    bar :: Day -> {-WeekOfYear-1-}Int64
    bar (ModifiedJulianDay k) = d7div - div k 7
    w0 = bar $ ModifiedJulianDay (d - fromIntegral yd + 4)
    (y1, w1) = case w0 of
        -1 -> (y0 - 1, foo (y0 - 1))
        52 | foo (y0 + 1) == 0 -> (y0 + 1, 0)
        _ -> (y0, w0)

{-# INLINE lastWeekOfYear #-}
lastWeekOfYear :: Year -> WeekOfYear
lastWeekOfYear y = if wdWeek wd == 53 then 53 else 52 where
    wd = view (from ordinalDate . weekDate) (OrdinalDate y 365)

{-# INLINE fromWeekLast #-}
fromWeekLast :: WeekOfYear -> WeekDate -> Day
fromWeekLast wMax (WeekDate y w d) = ModifiedJulianDay mjd where
    -- pilfered and refactored
    ModifiedJulianDay k = review ordinalDate (OrdinalDate y 6)
    mjd = k - mod k 7 - 10 + clip 1 7 (fromIntegral d)
        + fromIntegral (clip 1 wMax w) * 7
    clip a b = max a . min b

{-# INLINEABLE weekDateValid #-}
weekDateValid :: WeekDate -> Maybe Day
weekDateValid wd@(WeekDate (lastWeekOfYear -> wMax) w d) =
    fromWeekLast wMax wd <$ guard (1 <= d && d <= 7 && 1 <= w && w <= wMax)

{-# INLINEABLE showWeekDate #-}
showWeekDate :: Day -> String
showWeekDate (view weekDate -> WeekDate y w d) =
    shows04 y . (++) "-W" . shows02 w . (:) '-' . shows d $ ""

------------------------------------------------------------------------
-- * Non-standard week dates

-- | Weeks numbered from 0 to 53, starting with the first Sunday of the year
-- as the first day of week 1. The last week of a given year and week 0 of
-- the next both refer to the same week.
data SundayWeek = SundayWeek
    { swYear :: {-# UNPACK #-}!Year
    , swWeek :: {-# UNPACK #-}!WeekOfYear
    , swDay :: {-# UNPACK #-}!DayOfWeek
    } deriving (Eq, Ord, Data, Typeable, Show)

instance NFData SundayWeek

{-# INLINE sundayWeek #-}
sundayWeek :: Simple Iso Day SundayWeek
sundayWeek = iso toSunday fromSunday where

    {-# INLINEABLE toSunday #-}
    toSunday :: Day -> SundayWeek
    toSunday = join (toSundayOrdinal . view ordinalDate)

    {-# INLINEABLE fromSunday #-}
    fromSunday :: SundayWeek -> Day
    fromSunday (SundayWeek y w d) = ModifiedJulianDay (firstDay + yd) where
        ModifiedJulianDay firstDay = review ordinalDate (OrdinalDate y 1)
        -- following are all 0-based year days
        firstSunday = mod (4 - firstDay) 7
        yd = firstSunday + 7 * (fromIntegral w - 1) + fromIntegral d

{-# INLINE toSundayOrdinal #-}
toSundayOrdinal :: OrdinalDate -> Day -> SundayWeek
toSundayOrdinal (OrdinalDate y yd) (ModifiedJulianDay mjd) = SundayWeek y
        (fromIntegral $ d7div - div k 7) (fromIntegral d7mod) where
    d = mjd + 3
    k = d - fromIntegral yd
    (d7div, d7mod) = divMod d 7

{-# INLINEABLE sundayWeekValid #-}
sundayWeekValid :: SundayWeek -> Maybe Day
sundayWeekValid (SundayWeek y w d) = ModifiedJulianDay (firstDay + yd)
        <$ guard (0 <= d && d <= 6 && 0 <= yd && yd <= lastDay) where
    ModifiedJulianDay firstDay = review ordinalDate (OrdinalDate y 1)
    -- following are all 0-based year days
    firstSunday = mod (4 - firstDay) 7
    yd = firstSunday + 7 * (fromIntegral w - 1) + fromIntegral d
    lastDay = if isLeapYear y then 365 else 364

------------------------------------------------------------------------

-- | Weeks numbered from 0 to 53, starting with the first Monday of the year
-- as the first day of week 01. The last week of a given year and week 0 of
-- the next both refer to the same week, but not all 'DayOfWeek' are valid.
data MondayWeek = MondayWeek
    { mwYear :: {-# UNPACK #-}!Year
    , mwWeek :: {-# UNPACK #-}!WeekOfYear
    , mwDay :: {-# UNPACK #-}!DayOfWeek
    } deriving (Eq, Ord, Data, Typeable, Show)

instance NFData MondayWeek

{-# INLINE mondayWeek #-}
mondayWeek :: Simple Iso Day MondayWeek
mondayWeek = iso toMonday fromMonday where

    {-# INLINEABLE toMonday #-}
    toMonday :: Day -> MondayWeek
    toMonday = join (toMondayOrdinal . view ordinalDate)

    {-# INLINEABLE fromMonday #-}
    fromMonday :: MondayWeek -> Day
    fromMonday (MondayWeek y w d) = ModifiedJulianDay (firstDay + yd) where
        ModifiedJulianDay firstDay = review ordinalDate (OrdinalDate y 1)
        -- following are all 0-based year days
        firstMonday = mod (5 - firstDay) 7
        yd = firstMonday + 7 * (fromIntegral w - 1) + fromIntegral d - 1

{-# INLINE toMondayOrdinal #-}
toMondayOrdinal :: OrdinalDate -> Day -> MondayWeek
toMondayOrdinal (OrdinalDate y yd) (ModifiedJulianDay mjd) = MondayWeek y
        (fromIntegral $ d7div - div k 7) (fromIntegral $ d7mod + 1) where
    d = mjd + 2
    k = d - fromIntegral yd
    (d7div, d7mod) = divMod d 7

{-# INLINEABLE mondayWeekValid #-}
mondayWeekValid :: MondayWeek -> Maybe Day
mondayWeekValid (MondayWeek y w d) = ModifiedJulianDay (firstDay + yd)
        <$ guard (1 <= d && d <= 7 && 0 <= yd && yd <= lastDay) where
    ModifiedJulianDay firstDay = review ordinalDate (OrdinalDate y 1)
    -- following are all 0-based year days
    firstMonday = mod (5 - firstDay) 7
    yd = firstMonday + 7 * (fromIntegral w - 1) + fromIntegral d - 1
    lastDay = if isLeapYear y then 365 else 364

