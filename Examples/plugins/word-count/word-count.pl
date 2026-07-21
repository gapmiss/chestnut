#!/usr/bin/env perl
use strict;
use warnings;

my $text = do { local $/; <STDIN> };
$text //= '';

my @words = ($text =~ /\S+/g);
my $words = scalar @words;
my @sentences = ($text =~ /[.!?]+/g);
my $sentences = scalar @sentences || ($words > 0 ? 1 : 0);
my $chars = length($text);
my $chars_no_ws = ($text =~ s/\s//gr);
$chars_no_ws = length($chars_no_ws);

my $minutes = int($words / 238);
my $seconds = int(($words % 238) / (238 / 60));
my $reading_time;
if ($minutes > 0) {
    $reading_time = sprintf("%dm %ds", $minutes, $seconds);
} else {
    $reading_time = sprintf("%ds", $seconds);
}

printf("%d words \xC2\xB7 %d sentences \xC2\xB7 %s read\n%d chars (%d without spaces)",
    $words, $sentences, $reading_time, $chars, $chars_no_ws);
