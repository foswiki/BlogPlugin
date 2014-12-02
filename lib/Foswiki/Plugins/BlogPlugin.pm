# Plugin for Foswiki - The Free and Open Source Wiki, http://foswiki.org/
#
# Copyright (C) 2005-2014 Michael Daum http://michaeldaumconsulting.com
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details, published at
# http://www.gnu.org/copyleft/gpl.html
#
###############################################################################
package Foswiki::Plugins::BlogPlugin;

use strict;
use warnings;
use Error qw(:try);

our $VERSION = '3.00';
our $RELEASE = '3.00';
our $NO_PREFS_IN_TOPIC = 1;
our $SHORTDESCRIPTION = 'A blogging system for Foswiki';

###############################################################################
sub initPlugin {

  Foswiki::Func::registerRESTHandler('publish', \&handleBlogPublish, 
    authenticate => 1,
    validate => 0,
    http_allow => 'GET',
  );

  Foswiki::Func::registerRESTHandler('blogconvert', \&handleBlogConvert, 
    authenticate => 1,
    validate => 0,
    http_allow => 'GET',
  );

  return 1;
}

###############################################################################
sub handleBlogConvert {

  require Foswiki::Plugins::BlogPlugin::Converter;
  my $converter = new Foswiki::Plugins::BlogPlugin::Converter;

  my @params = @_;

  try {
    $converter->convert(@params);
  }
  catch Error::Simple with {
    my $error = shift;

    print STDERR "ERROR: " . $error->{-text} . "\n";
  };

  return "";
}

###############################################################################
sub handleBlogPublish {

  require Foswiki::Plugins::BlogPlugin::Publisher;
  my $publisher = new Foswiki::Plugins::BlogPlugin::Publisher;

  my @params = @_;

  try {
    $publisher->publish(@params);
  }
  catch Error::Simple with {
    my $error = shift;

    print STDERR "ERROR: " . $error->{-text} . "\n";
  };

  return "";
}

1;

