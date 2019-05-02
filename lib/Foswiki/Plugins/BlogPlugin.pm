# Plugin for Foswiki - The Free and Open Source Wiki, http://foswiki.org/
#
# Copyright (C) 2005-2019 Michael Daum http://michaeldaumconsulting.com
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
use Foswiki::Func();
use Foswiki::Plugins::DBCachePlugin();

our $VERSION = '5.00';
our $RELEASE = '2 May 2019';
our $NO_PREFS_IN_TOPIC = 1;
our $SHORTDESCRIPTION = 'A blogging system for Foswiki';

###############################################################################
sub initPlugin {

  Foswiki::Func::registerRESTHandler('publish', \&handleBlogPublish, 
    authenticate => 1,
    validate => 0,
    http_allow => 'GET',
  );

#  Foswiki::Func::registerRESTHandler('blogconvert', \&handleBlogConvert, 
#    authenticate => 1,
#    validate => 0,
#    http_allow => 'GET',
#  );

  Foswiki::Func::registerRESTHandler('importWordPress', \&handleImportWordPress, 
    authenticate => 1,
    validate => 0,
    http_allow => 'GET',
  );

  Foswiki::Func::registerRESTHandler('createRedirectMap', \&handleCreateRedirectMap, 
    authenticate => 1,
    validate => 0,
    http_allow => 'GET',
  );

  Foswiki::Plugins::DBCachePlugin::registerIndexTopicHandler(\&dbcacheIndexTopicHandler);

  if ($Foswiki::cfg{Plugins}{SolrPlugin} && $Foswiki::cfg{Plugins}{SolrPlugin}{Enabled}) {
    require Foswiki::Plugins::SolrPlugin;
    Foswiki::Plugins::SolrPlugin::registerIndexTopicHandler(sub {
      return indexTopicHandler(@_);
    });
  }

  return 1;
}

###############################################################################
sub handleImportWordPress {
  my $session = shift;

  require Foswiki::Plugins::BlogPlugin::ImportWordPress;
  my $importer = new Foswiki::Plugins::BlogPlugin::ImportWordPress($session);

  my @params = @_;

  try {
    $importer->import(@params);
  }
  catch Error::Simple with {
    my $error = shift;

    print STDERR "ERROR: " . $error->{-text} . "\n";
  };

  return "";
}

###############################################################################
sub handleCreateRedirectMap {
  my $session = shift;

  require Foswiki::Plugins::BlogPlugin::ImportWordPress;
  my $importer = new Foswiki::Plugins::BlogPlugin::ImportWordPress($session);

  my @params = @_;

  try {
    $importer->createRedirectMap(@params);
  }
  catch Error::Simple with {
    my $error = shift;

    print STDERR "ERROR: " . $error->{-text} . "\n";
  };

  return "";
}


###############################################################################
# convert blog to new format ... 
sub handleBlogConvert {

  require Foswiki::Plugins::BlogPlugin::Converter;
  my $converter = new Foswiki::Plugins::BlogPlugin::Converter();

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

##############################################################################
sub dbcacheIndexTopicHandler {
  my ($db, $obj, $web, $topic, $meta, $text) = @_;

  my $field = $meta->get('FIELD', 'TopicType');
  return unless $field;
  return unless $field->{value} =~ /\bBlogEntry\b/;

  my $publishDate;
  $field = $meta->get('FIELD', 'PublishDate');
  $field = $field->{value} if $field;
  $publishDate = Foswiki::Time::parseTime($field) if $field;
  $publishDate = $obj->fastget("createdate") unless $publishDate;

  $obj->set('publishdate', $publishDate);

  my $publishAuthor;
  $field = $meta->get('FIELD', 'Author');
  $publishAuthor = $field->{value} if $field;
  $publishAuthor = $obj->fastget("createauthor") unless $publishAuthor;

  $obj->set('publishauthor', $publishAuthor);
}

###############################################################################
sub indexTopicHandler {
  my ($indexer, $doc, $web, $topic, $meta, $text) = @_;

  ($meta) = Foswiki::Func::readTopic($web, $topic) unless $meta;

  my $formName = $meta->getFormName;
  return unless $formName && $formName =~ /BlogEntry/; # Hm, shall we make this a standard field?

  # normalize PublishDate, PublishAuthor
  my $publishDate;
  my $publishAuthor;

  my $field = $meta->get('FIELD', 'PublishDate');
  $publishDate = $field->{value} if $field;
  $publishDate = Foswiki::Time::parseTime($publishDate) if $publishDate;

  $field = $meta->get('FIELD', 'PublishAuthor');
  $publishAuthor = $field->{value} if $field;

  my ($createDate, $createAuthor) = Foswiki::Func::getRevisionInfo($web, $topic, 1);
  $publishDate = $createDate unless $publishDate;
  $publishAuthor = $createAuthor unless $publishAuthor;

  $publishDate = Foswiki::Time::formatTime($publishDate, '$iso', 'gmtime') if $publishDate;

  $field = $indexer->getField($doc, "field_PublishDate_dt");
  if ($field) {
    $field->value($publishDate);
  } else {
    $doc->add_fields('field_PublishDate_dt' => $publishDate);
  }

  $field = $indexer->getField($doc, "field_PublishAuthor_s");
  if ($field) {
    $field->value($publishDate);
  } else {
    $doc->add_fields('field_PublishAuthor_s' => $publishAuthor);
  }
}


1;

