require 'strscan'

# EmailReplyParser is a small library to parse plain text email content.  The
# goal is to identify which fragments are quoted, part of a signature, or
# original body content.  We want to support both top and bottom posters, so
# no simple "REPLY ABOVE HERE" content is used.
#
# Beyond RFC 5322 (which is handled by the [Ruby mail gem][mail]), there aren't
# any real standards for how emails are created.  This attempts to parse out
# common conventions for things like replies:
#
#     this is some text
#
#     On <date>, <author> wrote:
#     > blah blah
#     > blah blah
#
# ... and signatures:
#
#     this is some text
#
#     -- 
#     Bob
#     http://homepage.com/~bob
#
# Each of these are parsed into Fragment objects.
#
# EmailReplyParser also attempts to figure out which of these blocks should
# be hidden from users.
#
# [mail]: https://github.com/mikel/mail
class EmailReplyParser
  VERSION = "0.3.0"

  # Splits an email body into a list of Fragments.
  #
  # text - A String email body.
  #
  # Returns an Email instance.
  def self.read(text)
    Email.new.read(text)
  end

  ### Emails

  # An Email instance represents a parsed body String.
  class Email
    # Emails have an Array of Fragments.
    attr_reader :fragments

    def initialize
      @fragments = []
    end

    # Splits the given text into a list of Fragments.  This is roughly done by
    # reversing the text and parsing from the bottom to the top.  This way we
    # can check for 'On <date>, <author> wrote:' lines above quoted blocks.
    #
    # text - A String email body.
    #
    # Returns this same Email instance.
    def read(text)
      # The text is reversed initially due to the way we check for hidden
      # fragments.
      text = text.reverse

      # This determines if any 'visible' Fragment has been found.  Once any
      # visible Fragment is found, stop looking for hidden ones.
      @found_visible = false

      # This instance variable points to the current Fragment.  If the matched
      # line fits, it should be added to this Fragment.  Otherwise, finish it
      # and start a new Fragment.
      @fragment = nil

      # Use the StringScanner to pull out each line of the email content.
      @scanner = StringScanner.new(text)
      while line = @scanner.scan_until(/\n/)
        scan_line(line)
      end

      # Be sure to parse the last line of the email.
      if (last_line = @scanner.rest.to_s).size > 0
        scan_line(last_line)
      end

      # Finish up the final fragment.  Finishing a fragment will detect any
      # attributes (hidden, signature, reply), and join each line into a 
      # string.
      finish_fragment

      @scanner = @fragment = nil

      # Now that parsing is done, reverse the order.
      @fragments.reverse!
      self
    end

  private
    EMPTY = "".freeze

    ### Line-by-Line Parsing

    # Scans the given line of text and figures out which fragment it belongs
    # to.
    #
    # line - A String line of text from the email.
    #
    # Returns nothing.
    def scan_line(line)
      line.chomp!("\n")
      line.lstrip!

			is_quoted = check_for_quoted_text(line)
			is_signature = check_for_signature(line)
			is_quoted_header = check_for_quoted_headers(line)

			unless add_line_to_fragment(line, is_quoted, is_quoted_header)
				finish_fragment
				@fragment = Fragment.new(is_quoted, line)
			end
    end
		
		# We're looking for leading `>`'s to see if this line is part of a
		# quoted Fragment.
		def check_for_quoted_text(line)
      is_quoted = !!(line =~ /(>+)$/)
			is_quoted
		end

		def check_for_quoted_headers(line)
			is_quoted = !!(line =~ /^:etorw.*nO$/)
			is_quoted = check_for_hotmail_quoted_headers(line) unless is_quoted
			is_quoted
		end
		
		def check_for_hotmail_quoted_headers(line)
			is_quoted = !!(line =~ /(:morF+)$/) unless is_quoted
			is_quoted = !!(line =~ /(:oT+)$/) unless is_quoted
			is_quoted = !!(line =~ /(:tcejbuS+)$/) unless is_quoted
			is_quoted = !!(line =~ /(:etaD+)$/) unless is_quoted
			is_quoted
		end

		def check_for_outlook_quoted_headers(line)
			is_quoted = !!(line =~ /(:tneS+)$/) unless is_quoted
			is_quoted
		end

		# Mark the current Fragment as a signature if the current line is empty
		# and the Fragment starts with a common signature indicator.
		def check_for_signature(line)
      if @fragment && line == EMPTY
        if @fragment.lines.last =~ /[\-\_]$/
          @fragment.signature = true
          finish_fragment
        end
      end

			@fragment ? @fragment.signature? : false
		end

		# If the line matches the current fragment, add it.  Note that a common
		# reply header also counts as part of the quoted Fragment, even though
		# it doesn't start with `>`.
		def add_line_to_fragment(line, is_quoted, is_quoted_header)
			is_added = false

      if @fragment &&
          ((@fragment.quoted? == is_quoted) ||
           (@fragment.quoted? && (is_quoted_header || line == EMPTY)))
				@fragment.quoted = true if is_quoted_header && !is_quoted
        @fragment.lines << line
				is_added = true
      end

			is_added
		end

    # Builds the fragment string and reverses it, after all lines have been
    # added.  It also checks to see if this Fragment is hidden.  The hidden
    # Fragment check reads from the bottom to the top.
    #
    # Any quoted Fragments or signature Fragments are marked hidden if they
    # are below any visible Fragments.  Visible Fragments are expected to
    # contain original content by the author.  If they are below a quoted
    # Fragment, then the Fragment should be visible to give context to the
    # reply.
    #
    #     some original text (visible)
    #
    #     > do you have any two's? (quoted, visible)
    #
    #     Go fish! (visible)
    #
    #     > -- 
    #     > Player 1 (quoted, hidden)
    #
    #     -- 
    #     Player 2 (signature, hidden)
    #
    def finish_fragment
      if @fragment
        @fragment.finish

				# TODO: Move to it's own block to check if hidden
        if !@found_visible
          if @fragment.quoted? || @fragment.signature? ||
              @fragment.to_s.strip == EMPTY
            @fragment.hidden = true
          else
            @found_visible = true
          end
        end

        @fragments << @fragment
      end
      @fragment = nil
    end
  end

  ### Fragments

  # Represents a group of paragraphs in the email sharing common attributes.
  # Paragraphs should get their own fragment if they are a quoted area or a
  # signature.
  class Fragment < Struct.new(:quoted, :signature, :hidden)
    # This is an Array of String lines of content.  Since the content is
    # reversed, this array is backwards, and contains reversed strings.
    attr_reader :lines,

    # This is reserved for the joined String that is build when this Fragment
    # is finished.
      :content

    def initialize(quoted, first_line)
      self.signature = self.hidden = false
      self.quoted = quoted
      @lines      = [first_line]
      @content    = nil
      @lines.compact!
    end

    alias quoted?    quoted
    alias signature? signature
    alias hidden?    hidden

    # Builds the string content by joining the lines and reversing them.
    #
    # Returns nothing.
    def finish
      @content = @lines.join("\n")
      @lines = nil
      @content.reverse!
    end

    def to_s
      @content
    end

    def inspect
      to_s.inspect
    end
  end
end
