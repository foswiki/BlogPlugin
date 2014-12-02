# Plugin for Foswiki - The Free and Open Source Wiki, http://foswiki.org/
#
# Copyright (C) 2014 Michael Daum http://michaeldaumconsulting.com
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
package Foswiki::Plugins::BlogPlugin::Publisher;

use strict;
use warnings;
use Error qw(:try);
use Foswiki::Func ();
use Foswiki::Time ();

###############################################################################
sub new {
  my $class = shift;

  return bless({@_}, $class);
}

###############################################################################
sub writeDebug {
  my ($this, $msg) = @_;

  return unless $this->{debug};
  print STDERR "- BlogPlugin::Publisher - $msg\n";
}

###############################################################################
sub publish {
  my ($this, $session, $subject, $verb, $response) = @_;

  my $request = $session->{request};
  my $sourceWeb = $request->param("web") || $session->{webName};

  throw Error::Simple("no source web specified")
    unless $sourceWeb;

  throw Error::Simple("no such web $sourceWeb")
    unless Foswiki::Func::webExists($sourceWeb);

  $this->{debug} = Foswiki::Func::isTrue($request->param("debug"), 0);

  # search all BlogEntry topics in the source web
  my $matches = Foswiki::Func::query(
    'TopicType=~".*BlogEntry.*"',
    undef,
    {
      type => 'query',
      web => $sourceWeb,
    }
  );

  my $count = 0;
  my $now = Foswiki::Time::parseTime(Foswiki::Time::formatTime(time(), '$day $month $year'), 1);
  my $context = Foswiki::Func::getContext();

  while ($matches->hasNext) {
    my $webTopic = $matches->next;

    my ($web, $topic) = Foswiki::Func::normalizeWebTopicName($sourceWeb, $webTopic);

    my ($meta, $text) = Foswiki::Func::readTopic($web, $topic);

    my $state = $meta->get("FIELD", "State");
    next unless $state;

    my $publishEpoch;
    my $unpublishEpoch;

    my $publishDate = $meta->get("FIELD", "PublishDate");
    $publishEpoch = Foswiki::Time::parseTime($publishDate->{value}, 1)
      if defined $publishDate && $publishDate->{value};

    my $unpublishDate = $meta->get("FIELD", "UnpublishDate");
    $unpublishEpoch = Foswiki::Time::parseTime($unpublishDate->{value}, 1)
      if defined $unpublishDate && $unpublishDate->{value};

    my (undef, $user) = Foswiki::Func::getRevisionInfo($web, $topic);
    $user = Foswiki::Func::getCanonicalUserID($user);

    # decide on next state

    my $doSave;
    my $currentState = $state->{value} || 'published';
    my $newState;

    if ($currentState eq  'unpublished' && defined $publishEpoch && $now >= $publishEpoch) {
      $newState = 'published';
    }

    if (($currentState eq 'published' || (defined $newState && $newState eq 'published')) && defined $unpublishEpoch && $now >= $unpublishEpoch) {
      $newState = 'unpublished';
    } 

    next if !defined($newState) || $currentState eq $newState;
    $this->writeDebug("setting status to '$newState' for $topic");
    $state->{value} = $newState;

    # okay do it now
    my $tmpUser = $session->{user};
    $session->{user} = $user;

    Foswiki::Func::pushTopicContext($web, $topic);

    my $origTemplate = Foswiki::Func::getPreferencesValue('VIEW_TEMPLATE');
    my $template;

    if ($Foswiki::cfg{Plugins}{AutoTemplatePlugin}{Enabled}) {
      require Foswiki::Plugins::AutoTemplatePlugin;
      $template = Foswiki::Plugins::AutoTemplatePlugin::getTemplateName($web, $topic);

      if (!$origTemplate || $origTemplate ne $template) {
        Foswiki::Func::setPreferencesValue("VIEW_TEMPLATE", $template);
      } else {
        $origTemplate = undef;
      }
    }

    $context->{save} = 1;
    Foswiki::Func::saveTopic($web, $topic, $meta, $text);
    $context->{save} = 0;

    Foswiki::Func::setPreferencesValue("VIEW_TEMPLATE", $origTemplate)
      if defined $origTemplate;

    Foswiki::Func::popTopicContext();

    $session->{user} = $tmpUser;
    
    $count++;
    
  }

  $this->writeDebug("published $count blog entrie(s) in web $sourceWeb");
}

1;
