
use strict;
use warnings;

use 5.010001;

use ExtUtils::MakeMaker 6.30;



my %WriteMakefileArgs = (
  "ABSTRACT" => "Shell completion routines using Rinci metadata",
  "AUTHOR" => "Steven Haryanto <stevenharyanto\@gmail.com>",
  "BUILD_REQUIRES" => {},
  "CONFIGURE_REQUIRES" => {
    "ExtUtils::MakeMaker" => "6.30"
  },
  "DISTNAME" => "Perinci-Sub-Complete",
  "EXE_FILES" => [],
  "LICENSE" => "perl",
  "NAME" => "Perinci::Sub::Complete",
  "PREREQ_PM" => {
    "Log::Any" => 0,
    "Perinci::Sub::GetArgs::Argv" => "0.13",
    "Rinci" => "v1.1.10",
    "SHARYANTO::Complete::Util" => 0,
    "UUID::Random" => 0,
    "experimental" => 0
  },
  "TEST_REQUIRES" => {
    "File::Spec" => 0,
    "File::Which" => 0,
    "IO::Handle" => 0,
    "IPC::Open3" => 0,
    "Perinci::Sub::Wrapper" => 0,
    "Test::More" => "0.98"
  },
  "VERSION" => "0.34",
  "test" => {
    "TESTS" => "t/*.t"
  }
);


my %FallbackPrereqs = (
  "File::Spec" => 0,
  "File::Which" => 0,
  "IO::Handle" => 0,
  "IPC::Open3" => 0,
  "Log::Any" => 0,
  "Perinci::Sub::GetArgs::Argv" => "0.13",
  "Perinci::Sub::Wrapper" => 0,
  "Rinci" => "v1.1.10",
  "SHARYANTO::Complete::Util" => 0,
  "Test::More" => "0.98",
  "UUID::Random" => 0,
  "experimental" => 0
);


unless ( eval { ExtUtils::MakeMaker->VERSION(6.63_03) } ) {
  delete $WriteMakefileArgs{TEST_REQUIRES};
  delete $WriteMakefileArgs{BUILD_REQUIRES};
  $WriteMakefileArgs{PREREQ_PM} = \%FallbackPrereqs;
}

delete $WriteMakefileArgs{CONFIGURE_REQUIRES}
  unless eval { ExtUtils::MakeMaker->VERSION(6.52) };

WriteMakefile(%WriteMakefileArgs);



