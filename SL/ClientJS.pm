package SL::ClientJS;

use strict;

use parent qw(Rose::Object);

use Carp;
use SL::JSON ();

use Rose::Object::MakeMethods::Generic
(
  'scalar --get_set_init' => [ qw(_actions) ],
);

my %supported_methods = (
  # ## jQuery basics ##

  # Basic effects
  hide         => 1,
  show         => 1,
  toggle       => 1,

  # DOM insertion, around
  unwrap       => 1,
  wrap         => 2,
  wrapAll      => 2,
  wrapInner    => 2,

  # DOM insertion, inside
  append       => 2,
  appendTo     => 2,
  html         => 2,
  prepend      => 2,
  prependTo    => 2,
  text         => 2,

  # DOM insertion, outside
  after        => 2,
  before       => 2,
  insertAfter  => 2,
  insertBefore => 2,

  # DOM removal
  empty        => 1,
  remove       => 1,

  # DOM replacement
  replaceAll   => 2,
  replaceWith  => 2,

  # General attributes
  attr         => 3,
  prop         => 3,
  removeAttr   => 2,
  removeProp   => 2,
  val          => 2,

  # Data storage
  data         => 3,
  removeData   => 2,

  # Form Events
  focus        => 1,

  # ## jstree plugin ## pattern: $.jstree._reference($(<TARGET>)).<FUNCTION>(<ARGS>)

  # Operations on the whole tree
  'jstree:lock'          => 1,
  'jstree:unlock'        => 1,

  # Opening and closing nodes
  'jstree:open_node'     => 2,
  'jstree:open_all'      => 2,
  'jstree:close_node'    => 2,
  'jstree:close_all'     => 2,
  'jstree:toggle_node'   => 2,
  'jstree:save_opened'   => 1,
  'jstree:reopen'        => 1,

  # Modifying nodes
  'jstree:rename_node'   => 3,
  'jstree:delete_node'   => 2,
  'jstree:move_node'     => 5,

  # Selecting nodes (from the 'ui' plugin to jstree)
  'jstree:select_node'   => 2,  # $.jstree._reference($(<TARGET>)).<FUNCTION>(<ARGS>, true)
  'jstree:deselect_node' => 2,
  'jstree:deselect_all'  => 1,
);

sub AUTOLOAD {
  our $AUTOLOAD;

  my ($self, @args) = @_;

  my $method        =  $AUTOLOAD;
  $method           =~ s/.*:://;
  return if $method eq 'DESTROY';
  return $self->action($method, @args);
}

sub action {
  my ($self, $method, @args) = @_;

  $method      =  (delete($self->{_prefix}) || '') . $method;
  my $num_args =  $supported_methods{$method};

  croak "Unsupported jQuery action: $method"                                                    unless defined $num_args;
  croak "Parameter count mismatch for $method(actual: " . scalar(@args) . " wanted: $num_args)" if     scalar(@args) != $num_args;

  if ($num_args) {
    # Force flattening from SL::Presenter::EscapedText: "" . $...
    $args[0] =  "" . $args[0];
    $args[0] =~ s/^\s+//;
  }

  push @{ $self->_actions }, [ $method, @args ];

  return $self;
}

sub init__actions {
  return [];
}

sub to_json {
  my ($self) = @_;
  return SL::JSON::to_json({ eval_actions => $self->_actions });
}

sub to_array {
  my ($self) = @_;
  return $self->_actions;
}

sub render {
  my ($self, $controller) = @_;
  return $controller->render(\$self->to_json, { type => 'json' });
}

sub jstree {
  my ($self) = @_;
  $self->{_prefix} = 'jstree:';
  return $self;
}

1;
__END__

=pod

=encoding utf8

=head1 NAME

SL::ClientJS - Easy programmatic client-side JavaScript generation
with jQuery

=head1 SYNOPSIS

First some JavaScript code:

  // In the client generate an AJAX request whose 'success' handler
  // calls "eval_json_response(data)":
  var data = {
    action: "SomeController/the_action",
    id:     $('#some_input_field').val()
  };
  $.post("controller.pl", data, eval_json_response);

Now some Perl code:

  # In the controller itself. First, make sure that the "client_js.js"
  # is loaded. This must be done when the whole side is loaded, so
  # it's not in the action called by the AJAX request shown above.
  $::request->layout->use_javascript('client_js.js');

  # Now in that action called via AJAX:
  sub action_the_action {
    my ($self) = @_;

    # Create a new client-side JS object and do stuff with it!
    my $js = SL::ClientJS->new;

    # Show some element on the page:
    $js->show('#usually_hidden');

    # Set to hidden inputs. Yes, calls can be chained!
    $js->val('#hidden_id', $self->new_id)
       ->val('#other_type', 'Unicorn');

    # Replace some HTML code:
    my $html = $self->render('SomeController/the_action', { output => 0 });
    $js->html('#id_with_new_content', $html);

    # Operations on a jstree: rename a node and select it
    my $text_block = SL::DB::RequirementSpecTextBlock->new(id => 4711)->load;
    $js->jstree->rename_node('#tb-' . $text_block->id, $text_block->title)
       ->jstree->select_node('#tb-' . $text_block->id);

    # Finally render the JSON response:
    $self->render($js);

    # Rendering can also be chained, e.g.
    $js->html('#selector', $html)
       ->render($self);
  }

=head1 OVERVIEW

This module enables the generation of jQuery-using JavaScript code on
the server side. That code is then evaluated in a safe way on the
client side.

The workflow is usally that the client creates an AJAX request, the
server creates some actions and sends them back, and the client then
implements each of these actions.

There are three things that need to be done for this to work:

=over 2

=item 1. The "client_js.js" has to be loaded before the AJAX request is started.

=item 2. The client code needs to call C<eval_json_response()> with the result returned from the server.

=item 3. The server must use this module.

=back

The functions called on the client side are mostly jQuery
functions. Other functionality may be added later.

Note that L<SL::Controller/render> is aware of this module which saves
you some boilerplate. The following two calls are equivalent:

  $controller->render($client_js);
  $controller->render(\$client_js->to_json, { type => 'json' });

=head1 FUNCTIONS NOT PASSED TO THE CLIENT SIDE

=over 4

=item C<to_array>

Returns the actions gathered so far as an array reference. Each
element is an array reference containing at least two items: the
function's name and what it is called on. Additional array elements
are the function parameters.

=item C<to_json>

Returns the actions gathered so far as a JSON string ready to be sent
to the client.

=item C<render $controller>

Renders C<$self> via the controller. Useful for chaining. Equivalent
to the following:

  $controller->render(\$self->to_json, { type => 'json' });

=item C<jstree>

Tells C<$self> that the next action is to be called on a jstree
instance. For example:

  $js->jstree->rename_node('tb-' . $text_block->id, $text_block->title);

=back

=head1 FUNCTIONS EVALUATED ON THE CLIENT SIDE

=head2 GENERIC FUNCTION

All of the following functions can be invoked in two ways: either by
calling the function name directly on C<$self> or by calling
L</action> with the function name as the first parameter. Therefore
the following two calls are identical:

  $js->insertAfter($html, '#some-id');
  $js->action('insertAfter', $html, '#some-id');

The second form, calling L</action>, is more to type but can be useful
in situations in which you have to call one of two functions depending
on context. For example, when you want to insert new code in a
list. If the list is empty you might have to use C<appendTo>, if it
isn't you might have to use C<insertAfter>. Example:

  my $html = $self->render(...);
  $js->action($list_is_empty ? 'appendTo' : 'insertAfter', $html, '#text-block-' . ($list_is_empty ? 'list' : $self->text_block->id));

Instead of:

  my $html = $self->render(...);
  if ($list_is_empty) {
    $js->appendTo($html, '#text-block-list');
  } else {
    $js->insertAfter($html, '#text-block-' . $self->text_block->id);
  }

The first variation is obviously better suited for chaining.

=head2 JQUERY FUNCTIONS

The following jQuery functions are supported:

=over 4

=item Basic effects

C<hide>, C<show>, C<toggle>

=item DOM insertion, around

C<unwrap>, C<wrap>, C<wrapAll>, C<wrapInner>

=item DOM insertion, inside

C<append>, C<appendTo>, C<html>, C<prepend>, C<prependTo>, C<text>

=item DOM insertion, outside

C<after>, C<before>, C<insertAfter>, C<insertBefore>

=item DOM removal

C<empty>, C<remove>

=item DOM replacement

C<replaceAll>, C<replaceWith>

=item General attributes

C<attr>, C<prop>, C<removeAttr>, C<removeProp>, C<val>

=item Data storage

C<data>, C<removeData>

=item Form Events

C<focus>

=back

=head2 JSTREE JQUERY PLUGIN

The following functions of the C<jstree> plugin to jQuery are
supported:

=over 4

=item Operations on the whole tree

C<lock>, C<unlock>

=item Opening and closing nodes

C<open_node>, C<close_node>, C<toggle_node>, C<open_all>,
C<close_all>, C<save_opened>, C<reopen>

=item Modifying nodes

C<rename_node>, C<delete_node>, C<move_node>

=item Selecting nodes (from the 'ui' jstree plugin)

C<select_node>, C<deselect_node>, C<deselect_all>

=back

=head1 ADDING SUPPORT FOR ADDITIONAL FUNCTIONS

In order not having to maintain two files (this one and
C<js/client_js.js>) there's a script that can parse this file's
C<%supported_methods> definition and generate the file
C<js/client_js.js> accordingly. The steps are:

=over 2

=item 1. Add lines in this file to the C<%supported_methods> hash. The
key is the function name and the value is the number of expected
parameters.

=item 2. Run C<scripts/generate_client_js_actions.pl>. It will
generate C<js/client_js.js> automatically.

=item 3. Reload the files in your browser (cleaning its cache can also
help).

=back

The template file used for generated C<js/client_js.js> is
C<scripts/generate_client_js_actions.tpl>.

=head1 BUGS

Nothing here yet.

=head1 AUTHOR

Moritz Bunkus E<lt>m.bunkus@linet-services.deE<gt>

=cut